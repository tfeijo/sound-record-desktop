package server

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/tfeijo/sound-record-desktop/backend/meetdetect"
	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/pipeline"
	"github.com/tfeijo/sound-record-desktop/backend/store"
)

// Handlers holds dependencies for HTTP handler methods.
type Handlers struct {
	Store        *store.Store
	Hub          *Hub
	Pipeline     *pipeline.Runner
	MeetDetector *meetdetect.Detector
	AppCtx       context.Context // server lifecycle context for background work

	mu        sync.RWMutex
	state     string // idle, recording, processing, done, error
	meetingID string
	meetURL   string // Google Meet URL if auto-detected
}

// NewHandlers creates a Handlers with default recording state.
func NewHandlers(s *store.Store, hub *Hub, appCtx context.Context) *Handlers {
	return &Handlers{
		Store:    s,
		Hub:      hub,
		Pipeline: pipeline.NewRunner(s, hub),
		AppCtx:   appCtx,
		state:    "idle",
	}
}

// HealthCheck returns the service health status.
func (h *Handlers) HealthCheck(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"version": "0.1.0",
	})
}

// StartRecording handles POST /api/recording/start.
func (h *Handlers) StartRecording(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.state == "recording" {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": "already recording",
		})
		return
	}

	meetingID := uuid.New().String()
	now := time.Now().UTC()

	m := &models.Meeting{
		ID:        meetingID,
		Title:     "Untitled Meeting",
		Date:      now.Format("2006-01-02"),
		StartTime: &now,
		Status:    models.StatusRecording,
	}
	if err := h.Store.CreateMeeting(m); err != nil {
		log.Printf("Error creating meeting: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to create meeting"})
		return
	}

	h.state = "recording"
	h.meetingID = meetingID

	// Broadcast recording started via WebSocket
	h.Hub.Broadcast(Message{
		Type: "recording:started",
		Payload: map[string]string{
			"meetingId": meetingID,
		},
	})

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"meetingId": meetingID,
		"status":    "recording",
	})
}

// stopRecordingRequest is the expected JSON body for POST /api/recording/stop.
type stopRecordingRequest struct {
	MicPath    string `json:"micPath"`
	SystemPath string `json:"systemPath"`
	Duration   int    `json:"duration"` // seconds
}

// StopRecording handles POST /api/recording/stop.
func (h *Handlers) StopRecording(w http.ResponseWriter, r *http.Request) {
	// Parse optional body with file paths from Tauri
	var body stopRecordingRequest
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

	meetingID, hasAudio := h.stopRecordingLocked(body)

	// Trigger transcription pipeline in background (outside the lock)
	if meetingID != "" && hasAudio {
		h.Pipeline.RunAfterRecording(h.AppCtx, meetingID)
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "idle",
	})
}

// stopRecordingLocked handles all state changes under the mutex and returns
// the meeting ID and whether audio files exist for pipeline processing.
func (h *Handlers) stopRecordingLocked(body stopRecordingRequest) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()

	meetingID := h.meetingID
	hasAudio := body.MicPath != "" || body.SystemPath != ""

	if meetingID != "" {
		meeting, err := h.Store.GetMeeting(meetingID)
		if err == nil {
			now := time.Now().UTC()
			meeting.EndTime = &now
			if body.Duration > 0 {
				meeting.DurationSeconds = body.Duration
			} else if meeting.StartTime != nil {
				meeting.DurationSeconds = int(now.Sub(*meeting.StartTime).Seconds())
			}
			meeting.MicPath = body.MicPath
			meeting.SystemPath = body.SystemPath
			if hasAudio {
				meeting.Status = models.StatusTranscribing
			} else {
				meeting.Status = models.StatusDone
			}
			if err := h.Store.UpdateMeeting(meeting); err != nil {
				log.Printf("Error updating meeting on stop: %v", err)
			}
		}
	}

	h.Hub.Broadcast(Message{
		Type: "recording:stopped",
		Payload: map[string]string{
			"meetingId": meetingID,
		},
	})

	h.state = "idle"
	h.meetingID = ""
	h.meetURL = ""

	return meetingID, hasAudio
}

// GetRecordingStatus handles GET /api/recording/status.
func (h *Handlers) GetRecordingStatus(w http.ResponseWriter, r *http.Request) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	var meetingID interface{} = h.meetingID
	if h.meetingID == "" {
		meetingID = nil
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"state":     h.state,
		"meetingId": meetingID,
		"duration":  0,
	})
}

// ListMeetings handles GET /api/meetings.
func (h *Handlers) ListMeetings(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	offset, _ := strconv.Atoi(r.URL.Query().Get("offset"))
	if limit <= 0 || limit > 100 {
		limit = 50
	}

	meetings, err := h.Store.ListMeetings(limit, offset)
	if err != nil {
		log.Printf("Error listing meetings: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to list meetings"})
		return
	}
	if meetings == nil {
		meetings = []models.Meeting{}
	}
	writeJSON(w, http.StatusOK, meetings)
}

// GetMeeting handles GET /api/meetings/{id}.
func (h *Handlers) GetMeeting(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	meeting, err := h.Store.GetMeeting(id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "meeting not found"})
		return
	}
	if err != nil {
		log.Printf("Error getting meeting: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to get meeting"})
		return
	}
	writeJSON(w, http.StatusOK, meeting)
}

// RegenerateSummary handles POST /api/meetings/{id}/regenerate.
func (h *Handlers) RegenerateSummary(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	meeting, err := h.Store.GetMeeting(id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "meeting not found"})
		return
	}
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to get meeting"})
		return
	}
	if meeting.TranscriptJSON == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "no transcript to summarize"})
		return
	}

	// Run regeneration in background
	go func() {
		if err := h.Pipeline.RegenerateSummary(h.AppCtx, id); err != nil {
			log.Printf("[handler] Regenerate summary failed for %s: %v", id, err)
		}
	}()

	writeJSON(w, http.StatusAccepted, map[string]string{"status": "regenerating"})
}

// DeleteMeeting handles DELETE /api/meetings/{id}.
func (h *Handlers) DeleteMeeting(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	err := h.Store.DeleteMeeting(id)
	if err == sql.ErrNoRows {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "meeting not found"})
		return
	}
	if err != nil {
		log.Printf("Error deleting meeting: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to delete meeting"})
		return
	}
	writeJSON(w, http.StatusNoContent, nil)
}

// AutoStartRecording is called by the Meet detector when a meeting is detected.
// It only starts recording if auto-record is enabled and not already recording.
func (h *Handlers) AutoStartRecording(meetURL string) {
	autoRecord, _ := h.Store.GetSetting("auto_record")
	if autoRecord != "true" {
		log.Printf("[meetdetect] Auto-record disabled, ignoring Meet detection")
		return
	}

	h.mu.Lock()
	defer h.mu.Unlock()

	if h.state == "recording" {
		return
	}

	meetingID := uuid.New().String()
	now := time.Now().UTC()

	m := &models.Meeting{
		ID:        meetingID,
		Title:     "Google Meet",
		Date:      now.Format("2006-01-02"),
		StartTime: &now,
		Status:    models.StatusRecording,
		MeetURL:   meetURL,
	}
	if err := h.Store.CreateMeeting(m); err != nil {
		log.Printf("[meetdetect] Error creating meeting: %v", err)
		return
	}

	h.state = "recording"
	h.meetingID = meetingID
	h.meetURL = meetURL

	h.Hub.Broadcast(Message{
		Type: "recording:started",
		Payload: map[string]string{
			"meetingId": meetingID,
			"source":    "auto",
			"meetUrl":   meetURL,
		},
	})

	log.Printf("[meetdetect] Auto-started recording for meeting %s (URL: %s)", meetingID, meetURL)
}

// AutoStopRecording is called by the Meet detector when a meeting ends.
func (h *Handlers) AutoStopRecording() {
	meetingID, hasAudio := h.stopRecordingLocked(stopRecordingRequest{})

	if meetingID != "" && hasAudio {
		h.Pipeline.RunAfterRecording(h.AppCtx, meetingID)
	}

	log.Printf("[meetdetect] Auto-stopped recording for meeting %s", meetingID)
}

// GetMeetDetectStatus handles GET /api/meetdetect/status.
func (h *Handlers) GetMeetDetectStatus(w http.ResponseWriter, r *http.Request) {
	autoRecord, _ := h.Store.GetSetting("auto_record")
	inMeeting := false
	meetURL := ""
	if h.MeetDetector != nil {
		inMeeting = h.MeetDetector.InMeeting()
		meetURL = h.MeetDetector.CurrentURL()
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"enabled":   autoRecord == "true",
		"inMeeting": inMeeting,
		"meetUrl":   meetURL,
	})
}

// writeJSON encodes data as JSON and writes it to the response with the given status code.
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	if data == nil {
		w.WriteHeader(status)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("JSON encode error: %v", err)
	}
}
