package pipeline

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"

	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/obsidian"
	"github.com/tfeijo/sound-record-desktop/backend/store"
	"github.com/tfeijo/sound-record-desktop/backend/summarizer"
	"github.com/tfeijo/sound-record-desktop/backend/transcriber"
)

// Broadcaster is the interface for sending WebSocket events.
type Broadcaster interface {
	BroadcastJSON(msgType string, payload interface{})
}

// Runner orchestrates the recording pipeline: streaming transcription during recording,
// then summarization → Obsidian write after recording stops.
type Runner struct {
	store       *store.Store
	broadcast   Broadcaster
	sidecar     *transcriber.Sidecar
	scheduler   *transcriber.ChunkScheduler
	summarizer  *summarizer.Client
}

// NewRunner creates a pipeline runner.
func NewRunner(s *store.Store, b Broadcaster) *Runner {
	return &Runner{
		store:      s,
		broadcast:  b,
		sidecar:    transcriber.NewSidecar(),
		summarizer: summarizer.NewClient(),
	}
}

// StartStreaming starts the sidecar and chunk scheduler when recording begins.
// Called from the StartRecording handler with the meeting's audio file paths.
func (r *Runner) StartStreaming(ctx context.Context, meetingID, micPath, systemPath string) error {
	userName, _ := r.store.GetSetting("user_name")
	if userName == "" {
		userName = "User"
	}
	modelSize, _ := r.store.GetSetting("whisper_model_size")
	if modelSize == "" {
		modelSize = transcriber.ModelSizeBase
	}
	language, _ := r.store.GetSetting("language")

	profiles, _ := r.store.ListSpeakerProfiles()
	knownSpeakers := make([]string, 0, len(profiles))
	for _, p := range profiles {
		knownSpeakers = append(knownSpeakers, p.Name)
	}

	init := &transcriber.StreamInit{
		Type:          "init",
		ModelSize:     modelSize,
		Language:      language,
		UserName:      userName,
		KnownSpeakers: knownSpeakers,
	}

	ready, err := r.sidecar.Start(ctx, init)
	if err != nil {
		return fmt.Errorf("start sidecar: %w", err)
	}
	log.Printf("[pipeline] Sidecar ready: model=%s, device=%s", ready.ModelSize, ready.Device)

	scheduler, err := transcriber.NewChunkScheduler(r.sidecar, micPath, systemPath)
	if err != nil {
		_ = r.sidecar.Stop()
		return fmt.Errorf("create chunk scheduler: %w", err)
	}
	r.scheduler = scheduler
	r.scheduler.Start(ctx)

	r.broadcastStage(meetingID, "streaming_started")
	log.Printf("[pipeline] Streaming transcription started for meeting %s", meetingID)
	return nil
}

// FinalizeAndProcess stops the scheduler, finalizes the transcript, saves it,
// then runs summarization and Obsidian write. Runs in a goroutine.
func (r *Runner) FinalizeAndProcess(ctx context.Context, meetingID string) {
	go func() {
		r.broadcastStage(meetingID, "finalizing")

		if err := r.finalizeTranscription(meetingID); err != nil {
			log.Printf("[pipeline] Finalize failed for %s: %v", meetingID, err)
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
				r.broadcastStage(meetingID, "summary_error")
			} else {
				r.broadcastStage(meetingID, "summary_complete")
			}
		} else {
			log.Printf("[pipeline] Summarization skipped — ANTHROPIC_API_KEY not set")
		}

		// Obsidian write step
		vaultPath, _ := r.store.GetSetting("obsidian_vault_path")
		if vaultPath != "" {
			r.broadcastStage(meetingID, "writing_obsidian")

			if err := r.runObsidianWrite(meetingID, vaultPath); err != nil {
				log.Printf("[pipeline] Obsidian write failed for %s: %v", meetingID, err)
				r.broadcastStage(meetingID, "obsidian_error")
			} else {
				r.broadcastStage(meetingID, "obsidian_complete")
			}
		} else {
			log.Printf("[pipeline] Obsidian write skipped — vault path not configured")
		}

		// Mark as done
		r.updateMeetingStatus(meetingID, models.StatusDone)
		r.broadcastStage(meetingID, "complete")
		log.Printf("[pipeline] Pipeline complete for meeting %s", meetingID)
	}()
}

// StopStreaming stops the sidecar and scheduler without finalizing (e.g., on error/cancel).
func (r *Runner) StopStreaming() {
	if r.scheduler != nil {
		r.scheduler.Stop()
		r.scheduler.Cleanup()
		r.scheduler = nil
	}
	_ = r.sidecar.Stop()
}

// TranscribedSeconds returns how many seconds have been transcribed so far.
func (r *Runner) TranscribedSeconds() float64 {
	if r.scheduler != nil {
		return r.scheduler.TotalSeconds()
	}
	return 0
}

func (r *Runner) finalizeTranscription(meetingID string) error {
	// Stop the scheduler (sends final chunk)
	if r.scheduler != nil {
		r.scheduler.Stop()
		r.scheduler.Cleanup()
		r.scheduler = nil
	}

	// Finalize the sidecar — get complete transcript
	result, err := r.sidecar.Finalize()
	if err != nil {
		_ = r.sidecar.Stop()
		return fmt.Errorf("finalize sidecar: %w", err)
	}

	// Stop the sidecar process
	_ = r.sidecar.Stop()

	if result.Status == transcriber.StatusError {
		return fmt.Errorf("transcription error from sidecar")
	}

	// Convert FinalResult to the TranscriptionResponse format for DB storage
	resp := &transcriber.TranscriptionResponse{
		Status:           result.Status,
		DurationSeconds:  result.DurationSeconds,
		Segments:         result.Segments,
		Speakers:         result.Speakers,
		LanguageDetected: result.LanguageDetected,
		Warnings:         result.Warnings,
	}

	transcriptJSON, err := json.Marshal(resp)
	if err != nil {
		return fmt.Errorf("marshal transcript: %w", err)
	}

	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		return fmt.Errorf("get meeting: %w", err)
	}

	meeting.TranscriptJSON = string(transcriptJSON)
	meeting.SpeakerCount = len(resp.Speakers)
	if err := r.store.UpdateMeeting(meeting); err != nil {
		return fmt.Errorf("update meeting: %w", err)
	}

	log.Printf("[pipeline] Transcript saved: %d segments, %d speakers, %.0fs",
		len(resp.Segments), len(resp.Speakers), resp.DurationSeconds)

	return nil
}

// RegenerateSummary re-runs summarization for an existing meeting with a transcript.
func (r *Runner) RegenerateSummary(ctx context.Context, meetingID string) error {
	if !r.summarizer.Available() {
		return fmt.Errorf("ANTHROPIC_API_KEY not set")
	}

	r.broadcastStage(meetingID, "summarizing")
	r.updateMeetingStatus(meetingID, models.StatusSummarizing)

	if err := r.runSummarization(ctx, meetingID); err != nil {
		r.broadcastStage(meetingID, "summary_error")
		r.updateMeetingStatus(meetingID, models.StatusDone)
		return err
	}

	r.broadcastStage(meetingID, "summary_complete")

	vaultPath, _ := r.store.GetSetting("obsidian_vault_path")
	if vaultPath != "" {
		if err := r.runObsidianWrite(meetingID, vaultPath); err != nil {
			log.Printf("[pipeline] Obsidian re-write failed for %s: %v", meetingID, err)
		}
	}

	r.updateMeetingStatus(meetingID, models.StatusDone)
	r.broadcastStage(meetingID, "complete")
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

func (r *Runner) runObsidianWrite(meetingID, vaultPath string) error {
	meeting, err := r.store.GetMeeting(meetingID)
	if err != nil {
		return err
	}

	writer := obsidian.NewWriter(vaultPath)
	filePath, err := writer.Write(meeting)
	if err != nil {
		return err
	}

	meeting.ObsidianPath = filePath
	if err := r.store.UpdateMeeting(meeting); err != nil {
		return err
	}

	return nil
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
