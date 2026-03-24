package transcriber

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	// Audio format constants (must match wav_writer.rs: 16kHz mono 16-bit PCM)
	sampleRate    = 16000
	channels      = 1
	bitsPerSample = 16
	bytesPerFrame = channels * (bitsPerSample / 8) // 2 bytes per sample
	wavHeaderSize = 44                              // standard WAV header

	// Chunk timing
	defaultChunkInterval = 10 * time.Second
)

// ChunkScheduler monitors growing audio files during recording and periodically
// sends chunks to the sidecar for transcription.
type ChunkScheduler struct {
	sidecar       *Sidecar
	micPath       string // path to growing mic.wav
	systemPath    string // path to growing system.wav
	tmpDir        string // where to write chunk files
	chunkInterval time.Duration

	mu              sync.Mutex
	chunkID         int
	micOffset       int64   // bytes read so far from mic.wav (after header)
	systemOffset    int64   // bytes read so far from system.wav (after header)
	secondsOffset   float64 // cumulative seconds of audio sent
	cancel          context.CancelFunc
	done            chan struct{}
}

// NewChunkScheduler creates a scheduler that sends chunks to the given sidecar.
func NewChunkScheduler(sidecar *Sidecar, micPath, systemPath string) (*ChunkScheduler, error) {
	tmpDir, err := os.MkdirTemp("", "meetnotes-chunks-*")
	if err != nil {
		return nil, fmt.Errorf("create temp dir: %w", err)
	}

	return &ChunkScheduler{
		sidecar:       sidecar,
		micPath:       micPath,
		systemPath:    systemPath,
		tmpDir:        tmpDir,
		chunkInterval: defaultChunkInterval,
		done:          make(chan struct{}),
	}, nil
}

// Start begins the periodic chunk loop. It returns immediately.
func (cs *ChunkScheduler) Start(ctx context.Context) {
	cs.mu.Lock()
	ctx, cs.cancel = context.WithCancel(ctx)
	cs.mu.Unlock()

	go cs.loop(ctx)
}

// Stop signals the scheduler to stop and waits for it to finish.
// Returns after the last chunk is sent. Must be called after Start.
func (cs *ChunkScheduler) Stop() {
	cs.mu.Lock()
	cancelFn := cs.cancel
	cs.mu.Unlock()

	if cancelFn != nil {
		cancelFn()
	}
	<-cs.done
}

// Cleanup removes temporary chunk files.
func (cs *ChunkScheduler) Cleanup() {
	if cs.tmpDir != "" {
		_ = os.RemoveAll(cs.tmpDir)
	}
}

// TotalSeconds returns the total seconds of audio sent so far.
func (cs *ChunkScheduler) TotalSeconds() float64 {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	return cs.secondsOffset
}

func (cs *ChunkScheduler) loop(ctx context.Context) {
	defer close(cs.done)

	ticker := time.NewTicker(cs.chunkInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			// Send one final chunk with any remaining audio
			cs.sendChunk()
			return
		case <-ticker.C:
			cs.sendChunk()
		}
	}
}

func (cs *ChunkScheduler) sendChunk() {
	cs.mu.Lock()
	defer cs.mu.Unlock()

	chunkID := cs.chunkID
	offsetSeconds := cs.secondsOffset

	micChunkPath, micDuration, err := cs.extractChunk(cs.micPath, &cs.micOffset, "mic", chunkID)
	if err != nil {
		log.Printf("[scheduler] Warning: mic chunk %d extract failed: %v", chunkID, err)
	}

	sysChunkPath, sysDuration, err := cs.extractChunk(cs.systemPath, &cs.systemOffset, "system", chunkID)
	if err != nil {
		log.Printf("[scheduler] Warning: system chunk %d extract failed: %v", chunkID, err)
	}

	// Skip if no audio data in either source
	if micChunkPath == "" && sysChunkPath == "" {
		return
	}

	audioPaths := map[string]string{}
	if micChunkPath != "" {
		audioPaths["mic"] = micChunkPath
	}
	if sysChunkPath != "" {
		audioPaths["system"] = sysChunkPath
	}

	chunk := &StreamChunk{
		Type:          "chunk",
		ChunkID:       chunkID,
		AudioPaths:    audioPaths,
		OffsetSeconds: offsetSeconds,
	}

	log.Printf("[scheduler] Chunk %d sending: mic=%.1fs sys=%.1fs offset=%.1fs",
		chunkID, micDuration, sysDuration, offsetSeconds)

	result, err := cs.sidecar.SendChunk(chunk)
	if err != nil {
		log.Printf("[scheduler] Chunk %d failed: %v", chunkID, err)
	} else {
		log.Printf("[scheduler] Chunk %d processed: %d segments, lang=%s",
			result.ChunkID, len(result.Segments), result.LanguageDetected)
	}

	// Clean up temp chunk files after sidecar has read them
	if micChunkPath != "" {
		_ = os.Remove(micChunkPath)
	}
	if sysChunkPath != "" {
		_ = os.Remove(sysChunkPath)
	}

	// Update state for next chunk
	chunkDuration := max(micDuration, sysDuration)
	cs.secondsOffset += chunkDuration
	cs.chunkID++
}

// extractChunk reads new audio data from a growing WAV file since the last offset,
// writes it to a temporary WAV file, and returns the path and duration in seconds.
// Returns empty path if no new data is available.
func (cs *ChunkScheduler) extractChunk(sourcePath string, offset *int64, label string, chunkID int) (string, float64, error) {
	if sourcePath == "" {
		return "", 0, nil
	}

	f, err := os.Open(sourcePath)
	if err != nil {
		if os.IsNotExist(err) {
			return "", 0, nil // file not created yet
		}
		return "", 0, err
	}
	defer f.Close()

	// Get current file size
	stat, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	fileSize := stat.Size()

	// First read: skip WAV header.
	// NOTE: hound crate (wav_writer.rs) writes exactly 44-byte headers (RIFF + fmt + data).
	// If the WAV writer ever adds metadata chunks, this offset must be updated.
	dataStart := int64(wavHeaderSize)
	if *offset == 0 {
		*offset = dataStart
	}

	// Calculate available complete samples (avoid reading partial frames)
	available := fileSize - *offset
	available = (available / int64(bytesPerFrame)) * int64(bytesPerFrame) // align to frame boundary

	if available <= 0 {
		return "", 0, nil // no new data
	}

	// Read new audio data (handle short reads from growing file)
	buf := make([]byte, available)
	n, err := f.ReadAt(buf, *offset)
	if err != nil && err != io.EOF {
		return "", 0, fmt.Errorf("read at offset %d: %w", *offset, err)
	}
	// Re-align to frame boundary in case of short read
	n = (n / bytesPerFrame) * bytesPerFrame
	if n <= 0 {
		return "", 0, nil
	}
	buf = buf[:n]

	*offset += int64(n)

	// Calculate duration
	numSamples := int64(n) / int64(bytesPerFrame)
	duration := float64(numSamples) / float64(sampleRate)

	// Write chunk to temp WAV file
	chunkPath := filepath.Join(cs.tmpDir, fmt.Sprintf("chunk_%d_%s.wav", chunkID, label))
	if err := writeWAV(chunkPath, buf); err != nil {
		return "", 0, fmt.Errorf("write chunk wav: %w", err)
	}

	return chunkPath, duration, nil
}

// writeWAV creates a valid WAV file with the given PCM data.
// Uses the same format as the recording: 16kHz mono 16-bit PCM.
func writeWAV(path string, pcmData []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	dataSize := uint32(len(pcmData))
	fileSize := uint32(36 + dataSize) // 36 = header minus first 8 bytes

	// RIFF header
	if _, err := f.Write([]byte("RIFF")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, fileSize); err != nil {
		return err
	}
	if _, err := f.Write([]byte("WAVE")); err != nil {
		return err
	}

	// fmt sub-chunk
	if _, err := f.Write([]byte("fmt ")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(16)); err != nil { // sub-chunk size
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(1)); err != nil { // PCM format
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(channels)); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint32(sampleRate)); err != nil {
		return err
	}
	byteRate := uint32(sampleRate * channels * bitsPerSample / 8)
	if err := binary.Write(f, binary.LittleEndian, byteRate); err != nil {
		return err
	}
	blockAlign := uint16(channels * bitsPerSample / 8)
	if err := binary.Write(f, binary.LittleEndian, blockAlign); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, uint16(bitsPerSample)); err != nil {
		return err
	}

	// data sub-chunk
	if _, err := f.Write([]byte("data")); err != nil {
		return err
	}
	if err := binary.Write(f, binary.LittleEndian, dataSize); err != nil {
		return err
	}
	if _, err := f.Write(pcmData); err != nil {
		return err
	}

	return nil
}
