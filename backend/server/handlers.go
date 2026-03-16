package server

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/google/uuid"
)

// recordingState holds the current mock recording state.
type recordingState struct {
	mu        sync.RWMutex
	state     string // idle, recording, processing, done, error
	meetingID string
}

var currentRecording = &recordingState{state: "idle"}

// HealthCheck returns the service health status.
func HealthCheck(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"status":  "ok",
		"version": "0.1.0",
	})
}

// StartRecording handles POST /api/recording/start.
// Returns a mock response with a new meeting ID.
func StartRecording(w http.ResponseWriter, r *http.Request) {
	currentRecording.mu.Lock()
	defer currentRecording.mu.Unlock()

	if currentRecording.state == "recording" {
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": "already recording",
		})
		return
	}

	meetingID := uuid.New().String()
	currentRecording.state = "recording"
	currentRecording.meetingID = meetingID

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"meetingId": meetingID,
		"status":    "recording",
	})
}

// StopRecording handles POST /api/recording/stop.
func StopRecording(w http.ResponseWriter, r *http.Request) {
	currentRecording.mu.Lock()
	defer currentRecording.mu.Unlock()

	currentRecording.state = "idle"
	currentRecording.meetingID = ""

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "idle",
	})
}

// GetRecordingStatus handles GET /api/recording/status.
func GetRecordingStatus(w http.ResponseWriter, r *http.Request) {
	currentRecording.mu.RLock()
	defer currentRecording.mu.RUnlock()

	var meetingID interface{} = currentRecording.meetingID
	if currentRecording.meetingID == "" {
		meetingID = nil
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"state":     currentRecording.state,
		"meetingId": meetingID,
		"duration":  0,
	})
}

// writeJSON encodes data as JSON and writes it to the response with the given status code.
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("JSON encode error: %v", err)
	}
}
