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
	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/pipeline"
	"github.com/tfeijo/sound-record-desktop/backend/store"
)

// Handlers holds dependencies for HTTP handler methods.
type Handlers struct {
	Store    *store.Store
	Hub      *Hub
	Pipeline *pipeline.Runner

	mu        sync.RWMutex
	state     string // idle, recording, processing, done, error
	meetingID string
}

// NewHandlers creates a Handlers with default recording state.
func NewHandlers(s *store.Store, hub *Hub) *Handlers {
	return &Handlers{
		Store:    s,
		Hub:      hub,
		Pipeline: pipeline.NewRunner(s, hub),
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
	h.mu.Lock()

	// Parse optional body with file paths from Tauri
	var body stopRecordingRequest
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}

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
			// Set to processing if we have audio to transcribe, otherwise done
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

	// Broadcast recording stopped via WebSocket
	h.Hub.Broadcast(Message{
		Type: "recording:stopped",
		Payload: map[string]string{
			"meetingId": meetingID,
		},
	})

	h.state = "idle"
	h.meetingID = ""
	h.mu.Unlock()

	// Trigger transcription pipeline in background
	if meetingID != "" && hasAudio {
		h.Pipeline.RunAfterRecording(context.Background(), meetingID)
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "idle",
	})
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
