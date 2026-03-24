package transcriber

// Valid model sizes accepted by the Python sidecar.
const (
	ModelSizeTiny    = "tiny"
	ModelSizeBase    = "base"
	ModelSizeSmall   = "small"
	ModelSizeMedium  = "medium"
	ModelSizeLargeV2 = "large-v2"
)

// Valid result statuses returned by the Python sidecar.
const (
	StatusSuccess = "success"
	StatusPartial = "partial"
	StatusError   = "error"
)

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

// Segment represents a single transcribed speech segment.
type Segment struct {
	Speaker    string  `json:"speaker"`
	Start      float64 `json:"start"`
	End        float64 `json:"end"`
	Text       string  `json:"text"`
	Confidence float64 `json:"confidence"`
}

// SpeakerInfo holds aggregate information about a speaker in the transcript.
type SpeakerInfo struct {
	ID            string  `json:"id"`
	Source        string  `json:"source"` // "mic" or "system"
	TotalDuration float64 `json:"total_duration"`
}

// ---------------------------------------------------------------------------
// Streaming request messages  (Go → Python, one JSON per line on stdin)
// ---------------------------------------------------------------------------

// StreamInit is sent once when recording starts. Loads model + diarizer.
type StreamInit struct {
	Type          string   `json:"type"` // always "init"
	ModelSize     string   `json:"model_size"`
	Language      string   `json:"language,omitempty"`
	UserName      string   `json:"user_name"`
	KnownSpeakers []string `json:"known_speakers"`
}

// StreamChunk is sent every ~10s with new audio to transcribe.
type StreamChunk struct {
	Type           string            `json:"type"` // always "chunk"
	ChunkID        int               `json:"chunk_id"`
	AudioPaths     map[string]string `json:"audio_paths"`
	OffsetSeconds  float64           `json:"offset_seconds"`
}

// StreamFinalize is sent when recording stops to trigger final consolidation.
type StreamFinalize struct {
	Type string `json:"type"` // always "finalize"
}

// ---------------------------------------------------------------------------
// Streaming response messages  (Python → Go, one JSON per line on stdout)
// ---------------------------------------------------------------------------

// ReadyResponse is sent after init succeeds.
type ReadyResponse struct {
	Type      string `json:"type"` // always "ready"
	ModelSize string `json:"model_size"`
	Device    string `json:"device"`
}

// ChunkResult is sent after each chunk is processed.
type ChunkResult struct {
	Type             string    `json:"type"` // always "chunk_result"
	ChunkID          int       `json:"chunk_id"`
	Segments         []Segment `json:"segments"`
	LanguageDetected string    `json:"language_detected"`
	Warnings         []string  `json:"warnings"`
}

// FinalResult is the complete consolidated transcript, sent after finalize.
type FinalResult struct {
	Type             string        `json:"type"` // always "final_result"
	Status           string        `json:"status"` // "success", "partial", "error"
	DurationSeconds  float64       `json:"duration_seconds"`
	Segments         []Segment     `json:"segments"`
	Speakers         []SpeakerInfo `json:"speakers"`
	LanguageDetected string        `json:"language_detected"`
	Warnings         []string      `json:"warnings"`
}

// ErrorResponse is sent on any error (non-fatal, sidecar keeps running).
type ErrorResponse struct {
	Type    string `json:"type"` // always "error"
	ChunkID *int   `json:"chunk_id,omitempty"`
	Error   string `json:"error"`
}

// SidecarMessage is used to peek at the "type" field before full deserialization.
type SidecarMessage struct {
	Type string `json:"type"`
}

// ---------------------------------------------------------------------------
// Legacy types (used by current single-shot flow; will be removed once
// streaming is fully wired in US-005)
// ---------------------------------------------------------------------------

// TranscriptionRequest is the old single-shot JSON sent to the Python sidecar.
type TranscriptionRequest struct {
	AudioPaths    map[string]string `json:"audio_paths"`
	UserName      string            `json:"user_name"`
	Language      string            `json:"language,omitempty"`
	ModelSize     string            `json:"model_size"`
	KnownSpeakers []string          `json:"known_speakers"`
}

// TranscriptionResponse is the old single-shot JSON received from the Python sidecar.
type TranscriptionResponse struct {
	Status           string        `json:"status"` // "success", "partial", "error"
	DurationSeconds  float64       `json:"duration_seconds"`
	Segments         []Segment     `json:"segments"`
	Speakers         []SpeakerInfo `json:"speakers"`
	LanguageDetected string        `json:"language_detected"`
	Warnings         []string      `json:"warnings"`
	Error            string        `json:"error,omitempty"`
}
