package pipeline

import (
	"context"
	"encoding/json"
	"log"

	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/store"
	"github.com/tfeijo/sound-record-desktop/backend/transcriber"
)

// Broadcaster is the interface for sending WebSocket events.
type Broadcaster interface {
	BroadcastJSON(msgType string, payload interface{})
}

// Runner orchestrates the post-recording pipeline: transcription → (future: summarization → obsidian).
type Runner struct {
	store      *store.Store
	broadcast  Broadcaster
	transcriber *transcriber.Sidecar
}

// NewRunner creates a pipeline runner.
func NewRunner(s *store.Store, b Broadcaster) *Runner {
	return &Runner{
		store:       s,
		broadcast:   b,
		transcriber: transcriber.NewSidecar(),
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

		// Future: summarization step (US-014)
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

	// Update status to transcribing
	meeting.Status = models.StatusTranscribing
	if err := r.store.UpdateMeeting(meeting); err != nil {
		log.Printf("[pipeline] Failed to update status: %v", err)
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

	// Get user name from settings
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

	// Store transcript as JSON in meeting record
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
