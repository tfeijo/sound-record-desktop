package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/rs/cors"
)

// NewRouter creates and configures the chi router with all routes and middleware.
func NewRouter(hub *Hub, h *Handlers) http.Handler {
	r := chi.NewRouter()

	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Health check
	r.Get("/health", h.HealthCheck)

	// WebSocket endpoint
	r.Get("/ws", hub.HandleWebSocket)

	// API routes
	r.Route("/api", func(r chi.Router) {
		r.Get("/", func(w http.ResponseWriter, r *http.Request) {
			writeJSON(w, http.StatusOK, map[string]string{"message": "MeetNotes API"})
		})

		// Recording endpoints
		r.Post("/recording/start", h.StartRecording)
		r.Post("/recording/stop", h.StopRecording)
		r.Get("/recording/status", h.GetRecordingStatus)

		// Meetings CRUD
		r.Get("/meetings", h.ListMeetings)
		r.Get("/meetings/{id}", h.GetMeeting)
		r.Delete("/meetings/{id}", h.DeleteMeeting)
	})

	// Wrap with CORS for local development
	handler := cors.New(cors.Options{
		AllowedOrigins:   []string{"http://localhost:3100", "http://127.0.0.1:3100"},
		AllowedMethods:   []string{"GET", "POST", "PUT", "DELETE", "OPTIONS", "PATCH"},
		AllowedHeaders:   []string{"Content-Type", "Authorization"},
		AllowCredentials: false,
	}).Handler(r)

	return handler
}
