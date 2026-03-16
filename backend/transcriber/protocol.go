package transcriber

// TranscriptionRequest is the JSON sent to the Python sidecar via stdin.
type TranscriptionRequest struct {
	AudioPaths    map[string]string `json:"audio_paths"`
	UserName      string            `json:"user_name"`
	Language      string            `json:"language,omitempty"`
	ModelSize     string            `json:"model_size"`
	KnownSpeakers []string          `json:"known_speakers"`
}

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

// TranscriptionResponse is the JSON received from the Python sidecar via stdout.
type TranscriptionResponse struct {
	Status           string        `json:"status"` // "success", "partial", "error"
	DurationSeconds  float64       `json:"duration_seconds"`
	Segments         []Segment     `json:"segments"`
	Speakers         []SpeakerInfo `json:"speakers"`
	LanguageDetected string        `json:"language_detected"`
	Warnings         []string      `json:"warnings"`
	Error            string        `json:"error,omitempty"`
}
