package transcriber

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// Sidecar manages the Python ML sidecar process for transcription.
type Sidecar struct {
	PythonCmd  string // "python3" or path to venv python
	ScriptDir  string // absolute path to ml-sidecar directory
	Timeout    time.Duration
}

// NewSidecar creates a new Sidecar with default settings.
// scriptDir is resolved to an absolute path relative to the working directory.
func NewSidecar() *Sidecar {
	// Resolve ml-sidecar directory relative to the executable's location or cwd
	scriptDir := "ml-sidecar"
	if abs, err := filepath.Abs(scriptDir); err == nil {
		scriptDir = abs
	}

	pythonCmd := os.Getenv("MEETNOTES_PYTHON")
	if pythonCmd == "" {
		pythonCmd = "python3"
	} else if _, err := exec.LookPath(pythonCmd); err != nil {
		log.Printf("[transcriber] MEETNOTES_PYTHON=%q not found: %v, falling back to python3", pythonCmd, err)
		pythonCmd = "python3"
	}

	return &Sidecar{
		PythonCmd: pythonCmd,
		ScriptDir: scriptDir,
		Timeout:   30 * time.Minute, // long meetings need time
	}
}

// Transcribe spawns the Python sidecar, sends the request via stdin,
// and reads the response from stdout. The process is killed if ctx is cancelled.
func (s *Sidecar) Transcribe(ctx context.Context, req *TranscriptionRequest) (*TranscriptionResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, s.Timeout)
	defer cancel()

	// Marshal request to JSON
	input, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	log.Printf("[transcriber] Spawning Python sidecar: %s -m meetnotes_ml", s.PythonCmd)
	log.Printf("[transcriber] Request: model=%s, user=%s, paths=%v", req.ModelSize, req.UserName, req.AudioPaths)

	// Verify script directory exists
	if _, err := os.Stat(s.ScriptDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("ml-sidecar directory not found: %s", s.ScriptDir)
	}

	// Spawn the Python process
	cmd := exec.CommandContext(ctx, s.PythonCmd, "-m", "meetnotes_ml")
	cmd.Dir = s.ScriptDir
	cmd.Stdin = bytes.NewReader(input)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	startTime := time.Now()
	runErr := cmd.Run()

	elapsed := time.Since(startTime)

	// Log stderr (Python's logging goes there)
	if stderrStr := stderr.String(); stderrStr != "" {
		log.Printf("[transcriber] Python log:\n%s", stderrStr)
	}

	if runErr != nil {
		// Check if it was a timeout/cancellation
		if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("transcription timed out after %s", s.Timeout)
		}
		if ctx.Err() == context.Canceled {
			return nil, fmt.Errorf("transcription cancelled")
		}

		// Python may have written an error response to stdout before exiting non-zero
		if stdout.Len() > 0 {
			var resp TranscriptionResponse
			if jsonErr := json.Unmarshal(stdout.Bytes(), &resp); jsonErr == nil && resp.Error != "" {
				return &resp, fmt.Errorf("transcription error: %s", resp.Error)
			}
		}

		return nil, fmt.Errorf("python sidecar failed: %w", runErr)
	}

	log.Printf("[transcriber] Python sidecar completed in %s", elapsed.Round(time.Second))

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
