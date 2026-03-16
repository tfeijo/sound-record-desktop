package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/store"
	"github.com/tfeijo/sound-record-desktop/backend/summarizer"
	"github.com/tfeijo/sound-record-desktop/backend/transcriber"
)

// Broadcaster is the interface for sending WebSocket events.
type Broadcaster interface {
	BroadcastJSON(msgType string, payload interface{})
}

// Runner orchestrates the post-recording pipeline: transcription → summarization → (future: obsidian).
type Runner struct {
	store       *store.Store
	broadcast   Broadcaster
	transcriber *transcriber.Sidecar
	summarizer  *summarizer.Client
}

// NewRunner creates a pipeline runner.
func NewRunner(s *store.Store, b Broadcaster) *Runner {
	return &Runner{
		store:       s,
		broadcast:   b,
		transcriber: transcriber.NewSidecar(),
		summarizer:  summarizer.NewClient(),
	}
}

// RunAfterRecording executes the full pipeline for a meeting after recording stops.
// It runs in a goroutine and sends WebSocket events for progress.
func (r *Runner) RunAfterRecording(ctx context.Context, meetingID string) {
	go func() {
		r.broadcastStage(meetingID, "transcribing")

		if err := r.runTranscription(ctx, meetingID); err != nil {
			log.Printf("[pipeline] Transcription failed for %s: %v", meetingID, err)
			r.setMeetingError(meetingID, err.Error())
			r.broadcastError(meetingID, err.Error())
			return
		}

		r.broadcastStage(meetingID, "transcription_complete")

		// Summarization step
		if r.summarizer.Available() {
			r.broadcastStage(meetingID, "summarizing")
			r.updateMeetingStatus(meetingID, models.StatusSummarizing)

			if err := r.runSummarization(ctx, meetingID); err != nil {
				log.Printf("[pipeline] Summarization failed for %s: %v", meetingID, err)
				// Non-fatal: transcript is already saved, just log the error
				r.broadcastStage(meetingID, "summary_error")
			} else {
				r.broadcastStage(meetingID, "summary_complete")
			}
		} else {
			log.Printf("[pipeline] Summarization skipped — ANTHROPIC_API_KEY not set")
		}

		// Future: obsidian write step (US-015)

		// Mark as done
		r.updateMeetingStatus(meetingID, models.StatusDone)
		r.broadcastStage(meetingID, "complete")
		log.Printf("[pipeline] Pipeline complete for meeting %s", meetingID)
	}()
}

func (r *Runner) runTranscription(ctx context.Context, meetingID string) error {
	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		return err
	}

	// Build transcription request
	audioPaths := map[string]string{}
	if meeting.MicPath != "" {
		audioPaths["mic"] = meeting.MicPath
	}
	if meeting.SystemPath != "" {
		audioPaths["system"] = meeting.SystemPath
	}

	if len(audioPaths) == 0 {
		log.Printf("[pipeline] No audio paths for meeting %s, skipping transcription", meetingID)
		return nil
	}

	userName, _ := r.store.GetSetting("user_name")
	if userName == "" {
		userName = "User"
	}

	modelSize, _ := r.store.GetSetting("whisper_model_size")
	if modelSize == "" {
		modelSize = "base"
	}

	language, _ := r.store.GetSetting("language")

	req := &transcriber.TranscriptionRequest{
		AudioPaths:    audioPaths,
		UserName:      userName,
		Language:      language,
		ModelSize:     modelSize,
		KnownSpeakers: []string{},
	}

	resp, err := r.transcriber.Transcribe(ctx, req)
	if err != nil {
		return err
	}

	transcriptJSON, err := json.Marshal(resp)
	if err != nil {
		return err
	}

	meeting.TranscriptJSON = string(transcriptJSON)
	meeting.SpeakerCount = len(resp.Speakers)
	if err := r.store.UpdateMeeting(meeting); err != nil {
		return err
	}

	return nil
}

func (r *Runner) runSummarization(ctx context.Context, meetingID string) error {
	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		return err
	}

	if meeting.TranscriptJSON == "" {
		return fmt.Errorf("no transcript to summarize")
	}

	// Parse transcript to extract segments for the prompt
	var transcriptData struct {
		Segments []struct {
			Speaker string  `json:"speaker"`
			Start   float64 `json:"start"`
			End     float64 `json:"end"`
			Text    string  `json:"text"`
		} `json:"segments"`
	}
	if err := json.Unmarshal([]byte(meeting.TranscriptJSON), &transcriptData); err != nil {
		return fmt.Errorf("parse transcript: %w", err)
	}

	// Format transcript as readable text
	transcript := formatTranscript(transcriptData.Segments)
	if transcript == "" {
		return fmt.Errorf("empty transcript")
	}

	summary, err := r.summarizer.Summarize(ctx, transcript)
	if err != nil {
		return err
	}

	summaryJSON, err := json.Marshal(summary)
	if err != nil {
		return err
	}

	meeting.SummaryJSON = string(summaryJSON)
	// Update title if Claude provided one
	if summary.Title != "" {
		meeting.Title = summary.Title
	}
	if err := r.store.UpdateMeeting(meeting); err != nil {
		return err
	}

	return nil
}

func formatTranscript(segments []struct {
	Speaker string  `json:"speaker"`
	Start   float64 `json:"start"`
	End     float64 `json:"end"`
	Text    string  `json:"text"`
}) string {
	var buf bytes.Buffer
	for _, seg := range segments {
		minutes := int(seg.Start) / 60
		seconds := int(seg.Start) % 60
		fmt.Fprintf(&buf, "[%d:%02d] %s: %s\n", minutes, seconds, seg.Speaker, seg.Text)
	}
	return buf.String()
}

func (r *Runner) updateMeetingStatus(meetingID string, status models.MeetingStatus) {
	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		log.Printf("[pipeline] Failed to get meeting %s: %v", meetingID, err)
		return
	}
	meeting.Status = status
	if err := r.store.UpdateMeeting(meeting); err != nil {
		log.Printf("[pipeline] Failed to update meeting status: %v", err)
	}
}

func (r *Runner) setMeetingError(meetingID, errMsg string) {
	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		log.Printf("[pipeline] Failed to get meeting %s: %v", meetingID, err)
		return
	}
	meeting.Status = models.StatusError
	meeting.Error = errMsg
	if err := r.store.UpdateMeeting(meeting); err != nil {
		log.Printf("[pipeline] Failed to set meeting error: %v", err)
	}
}

func (r *Runner) broadcastStage(meetingID, stage string) {
	r.broadcast.BroadcastJSON("pipeline:stage", map[string]string{
		"meetingId": meetingID,
		"stage":     stage,
	})
}

func (r *Runner) broadcastError(meetingID, errMsg string) {
	r.broadcast.BroadcastJSON("pipeline:error", map[string]string{
		"meetingId": meetingID,
		"error":     errMsg,
	})
}
