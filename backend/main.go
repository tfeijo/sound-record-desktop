package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/tfeijo/sound-record-desktop/backend/meetdetect"
	"github.com/tfeijo/sound-record-desktop/backend/server"
	"github.com/tfeijo/sound-record-desktop/backend/store"
)

const defaultPort = "9876"

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}

	// Initialize SQLite store.
	dbPath := os.Getenv("MEETNOTES_DB_PATH")
	if dbPath == "" {
		dbPath = store.DefaultDBPath()
	}

	db, err := store.NewStore(dbPath)
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()

	log.Printf("Database opened at %s", dbPath)

	hub := server.NewHub()
	go hub.Run(ctx)

	handlers := server.NewHandlers(db, hub, ctx)

	// Start Google Meet auto-detection
	detector := meetdetect.NewDetector(hub, meetdetect.MeetCallback{
		OnMeetDetected: func(meetURL string) {
			handlers.AutoStartRecording(meetURL)
		},
		OnMeetEnded: func() {
			handlers.AutoStopRecording()
		},
	})
	handlers.MeetDetector = detector
	go detector.Run(ctx)

	router := server.NewRouter(hub, handlers)

	srv := &http.Server{
		Addr:        ":" + port,
		Handler:     router,
		ReadTimeout: 15 * time.Second,
		IdleTimeout: 60 * time.Second,
		// WriteTimeout intentionally omitted — it would kill long-lived WebSocket connections.
	}

	go func() {
		log.Printf("MeetNotes backend listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("Shutdown signal received, stopping server...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("Server shutdown error: %v", err)
	}

	log.Println("Server stopped")
}
