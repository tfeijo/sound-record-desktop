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
// scriptDir is resolved by searching: env var, next to executable, cwd, project root.
func NewSidecar() *Sidecar {
	scriptDir := findMLSidecarDir()

	pythonCmd := os.Getenv("MEETNOTES_PYTHON")
	if pythonCmd == "" {
		// Auto-detect venv Python next to ml-sidecar directory
		venvPython := filepath.Join(scriptDir, ".venv", "bin", "python3")
		if _, err := os.Stat(venvPython); err == nil {
			pythonCmd = venvPython
			log.Printf("[transcriber] Auto-detected venv Python: %s", pythonCmd)
		} else {
			pythonCmd = "python3"
		}
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

// findMLSidecarDir locates the ml-sidecar directory by checking multiple locations.
// Priority: MEETNOTES_ML_DIR env > next to executable > cwd > project root heuristic.
func findMLSidecarDir() string {
	// 1. Explicit env var
	if envDir := os.Getenv("MEETNOTES_ML_DIR"); envDir != "" {
		if abs, err := filepath.Abs(envDir); err == nil {
			return abs
		}
		return envDir
	}

	candidates := []string{}

	// 2. Relative to executable (for bundled app)
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(exeDir, "ml-sidecar"),
			filepath.Join(exeDir, "..", "..", "..", "ml-sidecar"), // src-tauri/target/debug/../../../ml-sidecar
		)
	}

	// 3. Relative to cwd
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates,
			filepath.Join(cwd, "ml-sidecar"),
			filepath.Join(cwd, "..", "ml-sidecar"),
		)
	}

	for _, c := range candidates {
		abs, err := filepath.Abs(c)
		if err != nil {
			continue
		}
		if info, err := os.Stat(abs); err == nil && info.IsDir() {
			log.Printf("[transcriber] Found ml-sidecar at: %s", abs)
			return abs
		}
	}

	// Fallback to cwd-relative (will error later with a clear message)
	fallback, _ := filepath.Abs("ml-sidecar")
	log.Printf("[transcriber] WARNING: ml-sidecar directory not found in any known location, using fallback: %s", fallback)
	return fallback
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
