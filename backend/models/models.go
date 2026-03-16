package models

import "time"

// MeetingStatus represents the lifecycle state of a meeting.
type MeetingStatus string

const (
	StatusRecording    MeetingStatus = "recording"
	StatusTranscribing MeetingStatus = "transcribing"
	StatusSummarizing  MeetingStatus = "summarizing"
	StatusDone         MeetingStatus = "done"
	StatusError        MeetingStatus = "error"
)

// Meeting represents a recorded meeting with its metadata, transcript, and summary.
type Meeting struct {
	ID              string        `json:"id"`
	Title           string        `json:"title"`
	Date            string        `json:"date"`
	StartTime       *time.Time    `json:"startTime,omitempty"`
	EndTime         *time.Time    `json:"endTime,omitempty"`
	DurationSeconds int           `json:"durationSeconds"`
	SpeakerCount    int           `json:"speakerCount"`
	Status          MeetingStatus `json:"status"`
	AudioPath       string        `json:"audioPath,omitempty"`
	MicPath         string        `json:"micPath,omitempty"`
	SystemPath      string        `json:"systemPath,omitempty"`
	TranscriptJSON  string        `json:"transcriptJson,omitempty"`
	SummaryJSON     string        `json:"summaryJson,omitempty"`
	ObsidianPath    string        `json:"obsidianPath,omitempty"`
	MeetURL         string        `json:"meetUrl,omitempty"`
	Error           string        `json:"error,omitempty"`
	CreatedAt       time.Time     `json:"createdAt"`
	UpdatedAt       time.Time     `json:"updatedAt"`
}

// SpeakerProfile represents a known speaker with an optional voice embedding for identification.
type SpeakerProfile struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	EmbeddingPath string    `json:"embeddingPath,omitempty"`
	CreatedAt     time.Time `json:"createdAt"`
}
