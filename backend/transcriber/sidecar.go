package transcriber

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// Sidecar manages a long-running Python ML sidecar process for streaming transcription.
type Sidecar struct {
	PythonCmd string        // "python3" or path to venv python
	ScriptDir string        // absolute path to ml-sidecar directory
	Timeout   time.Duration // timeout for finalize response

	mu      sync.Mutex
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	stdout  *bufio.Scanner
	stderr  io.ReadCloser
	running bool
}

// NewSidecar creates a new Sidecar with default settings.
func NewSidecar() *Sidecar {
	scriptDir := findMLSidecarDir()

	pythonCmd := os.Getenv("MEETNOTES_PYTHON")
	if pythonCmd == "" {
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
		Timeout:   5 * time.Minute,
	}
}

// findMLSidecarDir locates the ml-sidecar directory by checking multiple locations.
func findMLSidecarDir() string {
	if envDir := os.Getenv("MEETNOTES_ML_DIR"); envDir != "" {
		if abs, err := filepath.Abs(envDir); err == nil {
			return abs
		}
		return envDir
	}

	candidates := []string{}

	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(exeDir, "ml-sidecar"),
			filepath.Join(exeDir, "..", "..", "..", "ml-sidecar"),
		)
	}

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

	fallback, _ := filepath.Abs("ml-sidecar")
	log.Printf("[transcriber] WARNING: ml-sidecar directory not found, using fallback: %s", fallback)
	return fallback
}

// Start spawns the Python sidecar process and sends an init message.
// It waits for a 'ready' response before returning.
func (s *Sidecar) Start(ctx context.Context, init *StreamInit) (*ReadyResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return nil, fmt.Errorf("sidecar already running")
	}

	if _, err := os.Stat(s.ScriptDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("ml-sidecar directory not found: %s", s.ScriptDir)
	}

	init.Type = "init"

	log.Printf("[transcriber] Starting persistent sidecar: %s -m meetnotes_ml", s.PythonCmd)

	cmd := exec.CommandContext(ctx, s.PythonCmd, "-m", "meetnotes_ml")
	cmd.Dir = s.ScriptDir

	stdinPipe, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("create stdin pipe: %w", err)
	}

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create stdout pipe: %w", err)
	}

	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("create stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start python sidecar: %w", err)
	}

	s.cmd = cmd
	s.stdin = stdinPipe
	s.stdout = bufio.NewScanner(stdoutPipe)
	s.stdout.Buffer(make([]byte, 0, 1024*1024), 10*1024*1024) // 10MB max line
	s.stderr = stderrPipe
	s.running = true

	// Continuously drain stderr in background
	go s.drainStderr()

	// Send init message
	if err := s.writeJSON(init); err != nil {
		s.killLocked()
		return nil, fmt.Errorf("send init: %w", err)
	}

	// Read ready response
	resp, err := s.readResponse()
	if err != nil {
		s.killLocked()
		return nil, fmt.Errorf("read init response: %w", err)
	}

	var msg SidecarMessage
	if err := json.Unmarshal(resp, &msg); err != nil {
		s.killLocked()
		return nil, fmt.Errorf("parse response type: %w", err)
	}

	if msg.Type == "error" {
		var errResp ErrorResponse
		_ = json.Unmarshal(resp, &errResp)
		s.killLocked()
		return nil, fmt.Errorf("sidecar init failed: %s", errResp.Error)
	}

	if msg.Type != "ready" {
		s.killLocked()
		return nil, fmt.Errorf("unexpected response type: %s (expected 'ready')", msg.Type)
	}

	var ready ReadyResponse
	if err := json.Unmarshal(resp, &ready); err != nil {
		s.killLocked()
		return nil, fmt.Errorf("parse ready response: %w", err)
	}

	log.Printf("[transcriber] Sidecar ready: model=%s, device=%s", ready.ModelSize, ready.Device)
	return &ready, nil
}

// SendChunk sends a chunk request and reads the chunk result.
// Thread-safe: multiple goroutines can call this but writes are serialized.
func (s *Sidecar) SendChunk(chunk *StreamChunk) (*ChunkResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return nil, fmt.Errorf("sidecar not running")
	}

	chunk.Type = "chunk"

	if err := s.writeJSON(chunk); err != nil {
		return nil, fmt.Errorf("send chunk %d: %w", chunk.ChunkID, err)
	}

	resp, err := s.readResponse()
	if err != nil {
		return nil, fmt.Errorf("read chunk %d response: %w", chunk.ChunkID, err)
	}

	var msg SidecarMessage
	if err := json.Unmarshal(resp, &msg); err != nil {
		return nil, fmt.Errorf("parse chunk response type: %w", err)
	}

	if msg.Type == "error" {
		var errResp ErrorResponse
		_ = json.Unmarshal(resp, &errResp)
		return nil, fmt.Errorf("chunk %d error: %s", chunk.ChunkID, errResp.Error)
	}

	if msg.Type != "chunk_result" {
		return nil, fmt.Errorf("unexpected response type for chunk %d: %s", chunk.ChunkID, msg.Type)
	}

	var result ChunkResult
	if err := json.Unmarshal(resp, &result); err != nil {
		return nil, fmt.Errorf("parse chunk result: %w", err)
	}

	return &result, nil
}

// Finalize sends the finalize message and returns the complete transcript.
func (s *Sidecar) Finalize() (*FinalResult, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return nil, fmt.Errorf("sidecar not running")
	}

	fin := &StreamFinalize{Type: "finalize"}
	if err := s.writeJSON(fin); err != nil {
		return nil, fmt.Errorf("send finalize: %w", err)
	}

	resp, err := s.readResponse()
	if err != nil {
		return nil, fmt.Errorf("read finalize response: %w", err)
	}

	var msg SidecarMessage
	if err := json.Unmarshal(resp, &msg); err != nil {
		return nil, fmt.Errorf("parse finalize response type: %w", err)
	}

	if msg.Type == "error" {
		var errResp ErrorResponse
		_ = json.Unmarshal(resp, &errResp)
		return nil, fmt.Errorf("finalize error: %s", errResp.Error)
	}

	if msg.Type != "final_result" {
		return nil, fmt.Errorf("unexpected response type: %s (expected 'final_result')", msg.Type)
	}

	var result FinalResult
	if err := json.Unmarshal(resp, &result); err != nil {
		return nil, fmt.Errorf("parse final result: %w", err)
	}

	log.Printf("[transcriber] Finalize: status=%s, segments=%d, speakers=%d",
		result.Status, len(result.Segments), len(result.Speakers))

	return &result, nil
}

// Stop gracefully shuts down the sidecar by closing stdin and waiting for exit.
func (s *Sidecar) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return nil
	}

	log.Printf("[transcriber] Stopping sidecar...")

	// Close stdin to signal the Python process to exit
	if s.stdin != nil {
		_ = s.stdin.Close()
	}

	// Wait for process exit with timeout
	done := make(chan error, 1)
	go func() {
		done <- s.cmd.Wait()
	}()

	select {
	case err := <-done:
		s.running = false
		if err != nil {
			log.Printf("[transcriber] Sidecar exited with: %v", err)
		} else {
			log.Printf("[transcriber] Sidecar exited cleanly")
		}
		return err
	case <-time.After(10 * time.Second):
		s.killLocked()
		return fmt.Errorf("sidecar did not exit within 10s, killed")
	}
}

// IsAlive returns true if the sidecar process is still running.
func (s *Sidecar) IsAlive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running || s.cmd == nil || s.cmd.Process == nil {
		return false
	}
	// Check if process has exited
	if s.cmd.ProcessState != nil {
		s.running = false
		return false
	}
	return true
}

// writeJSON marshals v to JSON, writes it as a single line to stdin, and flushes.
// Caller must hold s.mu.
func (s *Sidecar) writeJSON(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal: %w", err)
	}
	data = append(data, '\n')
	if _, err := s.stdin.Write(data); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	return nil
}

// readResponse reads one JSON line from stdout.
// Caller must hold s.mu.
func (s *Sidecar) readResponse() ([]byte, error) {
	if !s.stdout.Scan() {
		err := s.stdout.Err()
		if err != nil {
			return nil, fmt.Errorf("read stdout: %w", err)
		}
		return nil, fmt.Errorf("sidecar closed stdout unexpectedly")
	}
	return s.stdout.Bytes(), nil
}

// drainStderr continuously reads stderr and logs it.
func (s *Sidecar) drainStderr() {
	scanner := bufio.NewScanner(s.stderr)
	scanner.Buffer(make([]byte, 0, 64*1024), 256*1024)
	for scanner.Scan() {
		log.Printf("[transcriber:python] %s", scanner.Text())
	}
}

// killLocked forcefully kills the sidecar process. Caller must hold s.mu.
func (s *Sidecar) killLocked() {
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	s.running = false
}

// ---------------------------------------------------------------------------
// Legacy single-shot method (used by current pipeline; will be removed in US-005)
// ---------------------------------------------------------------------------

// Transcribe spawns a one-shot Python sidecar, sends the request via stdin,
// and reads the response from stdout.
func (s *Sidecar) Transcribe(ctx context.Context, req *TranscriptionRequest) (*TranscriptionResponse, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()

	input, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	log.Printf("[transcriber] Spawning one-shot Python sidecar: %s -m meetnotes_ml", s.PythonCmd)

	if _, err := os.Stat(s.ScriptDir); os.IsNotExist(err) {
		return nil, fmt.Errorf("ml-sidecar directory not found: %s", s.ScriptDir)
	}

	cmd := exec.CommandContext(ctx, s.PythonCmd, "-m", "meetnotes_ml")
	cmd.Dir = s.ScriptDir

	var stdinBuf, stdout, stderr [0]byte
	_ = stdinBuf
	cmd.Stdin = &readCloserBuf{data: input}

	var stdoutBuf, stderrBuf limitedBuffer
	stdoutBuf.max = 10 * 1024 * 1024
	stderrBuf.max = 1 * 1024 * 1024
	cmd.Stdout = &stdoutBuf
	cmd.Stderr = &stderrBuf
	_ = stdout
	_ = stderr

	startTime := time.Now()
	runErr := cmd.Run()
	elapsed := time.Since(startTime)

	if stderrStr := stderrBuf.String(); stderrStr != "" {
		log.Printf("[transcriber] Python log:\n%s", stderrStr)
	}

	if runErr != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return nil, fmt.Errorf("transcription timed out after %s", 30*time.Minute)
		}
		if ctx.Err() == context.Canceled {
			return nil, fmt.Errorf("transcription cancelled")
		}
		if stdoutBuf.Len() > 0 {
			var resp TranscriptionResponse
			if jsonErr := json.Unmarshal(stdoutBuf.Bytes(), &resp); jsonErr == nil && resp.Error != "" {
				return &resp, fmt.Errorf("transcription error: %s", resp.Error)
			}
		}
		return nil, fmt.Errorf("python sidecar failed: %w", runErr)
	}

	log.Printf("[transcriber] Python sidecar completed in %s", elapsed.Round(time.Second))

	var resp TranscriptionResponse
	if err := json.Unmarshal(stdoutBuf.Bytes(), &resp); err != nil {
		return nil, fmt.Errorf("unmarshal response: %w (raw: %s)", err, stdoutBuf.String())
	}

	if resp.Status == "error" {
		return &resp, fmt.Errorf("transcription error: %s", resp.Error)
	}

	log.Printf("[transcriber] Result: status=%s, segments=%d, speakers=%d, language=%s",
		resp.Status, len(resp.Segments), len(resp.Speakers), resp.LanguageDetected)

	return &resp, nil
}

// readCloserBuf wraps a byte slice as an io.Reader for cmd.Stdin.
type readCloserBuf struct {
	data []byte
	pos  int
}

func (r *readCloserBuf) Read(p []byte) (int, error) {
	if r.pos >= len(r.data) {
		return 0, io.EOF
	}
	n := copy(p, r.data[r.pos:])
	r.pos += n
	return n, nil
}

// limitedBuffer is a bytes.Buffer with a maximum size.
type limitedBuffer struct {
	buf []byte
	max int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	remaining := b.max - len(b.buf)
	if remaining <= 0 {
		return len(p), nil // silently discard
	}
	if len(p) > remaining {
		p = p[:remaining]
	}
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *limitedBuffer) Bytes() []byte  { return b.buf }
func (b *limitedBuffer) String() string { return string(b.buf) }
func (b *limitedBuffer) Len() int       { return len(b.buf) }
