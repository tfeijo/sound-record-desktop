package transcriber

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"time"
)

// Sidecar manages the Python ML sidecar process for transcription.
type Sidecar struct {
	pythonCmd string // "python3" or path to venv python
	timeout   time.Duration
}

// NewSidecar creates a new Sidecar with default settings.
func NewSidecar() *Sidecar {
	return &Sidecar{
		pythonCmd: "python3",
		timeout:   30 * time.Minute, // long meetings need time
	}
}

// Transcribe spawns the Python sidecar, sends the request via stdin,
// and reads the response from stdout. The process is killed if ctx is cancelled.
func (s *Sidecar) Transcribe(ctx context.Context, req *TranscriptionRequest) (*TranscriptionResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, s.timeout)
	defer cancel()

	// Marshal request to JSON
	input, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	log.Printf("[transcriber] Spawning Python sidecar: %s -m meetnotes_ml", s.pythonCmd)
	log.Printf("[transcriber] Request: model=%s, user=%s, paths=%v", req.ModelSize, req.UserName, req.AudioPaths)

	// Spawn the Python process
	cmd := exec.CommandContext(ctx, s.pythonCmd, "-m", "meetnotes_ml")
	cmd.Dir = "ml-sidecar" // run from the ml-sidecar directory
	cmd.Stdin = bytes.NewReader(input)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	startTime := time.Now()
	if err := cmd.Run(); err != nil {
		stderrStr := stderr.String()
		if stderrStr != "" {
			log.Printf("[transcriber] Python stderr:\n%s", stderrStr)
		}
		return nil, fmt.Errorf("python sidecar failed: %w", err)
	}

	elapsed := time.Since(startTime)
	log.Printf("[transcriber] Python sidecar completed in %s", elapsed.Round(time.Second))

	// Log stderr (Python's logging goes there)
	if stderrStr := stderr.String(); stderrStr != "" {
		log.Printf("[transcriber] Python log:\n%s", stderrStr)
	}

	// Parse response
	var resp TranscriptionResponse
	if err := json.Unmarshal(stdout.Bytes(), &resp); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w (raw: %s)", err, stdout.String())
	}

	if resp.Status == "error" {
		return &resp, fmt.Errorf("transcription error: %s", resp.Error)
	}

	log.Printf("[transcriber] Result: status=%s, segments=%d, speakers=%d, language=%s",
		resp.Status, len(resp.Segments), len(resp.Speakers), resp.LanguageDetected)

	return &resp, nil
}
