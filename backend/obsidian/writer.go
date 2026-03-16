package obsidian

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/tfeijo/sound-record-desktop/backend/models"
	"github.com/tfeijo/sound-record-desktop/backend/summarizer"
)

// templateData holds all data needed to render the Obsidian markdown template.
type templateData struct {
	Title       string
	Date        string
	Duration    string
	Speakers    []string
	Summary     string
	Decisions   []string
	ActionItems []summarizer.ActionItem
	Topics      []summarizer.Topic
	Segments    []templateSegment
}

type templateSegment struct {
	Speaker   string
	Timestamp string
	Text      string
}

// Writer writes meeting reports to an Obsidian vault.
type Writer struct {
	vaultPath string
}

// NewWriter creates an Obsidian Writer for the given vault path.
func NewWriter(vaultPath string) *Writer {
	return &Writer{vaultPath: vaultPath}
}

// Write renders a meeting as markdown and saves it to the Obsidian vault.
// Returns the file path of the written markdown file.
func (w *Writer) Write(meeting *models.Meeting) (string, error) {
	if w.vaultPath == "" {
		return "", fmt.Errorf("obsidian vault path not configured")
	}

	data, err := buildTemplateData(meeting)
	if err != nil {
		return "", fmt.Errorf("build template data: %w", err)
	}

	// Render template
	var buf bytes.Buffer
	if err := meetingTemplate.Execute(&buf, data); err != nil {
		return "", fmt.Errorf("execute template: %w", err)
	}

	// Ensure Meetings/ directory exists
	meetingsDir := filepath.Join(w.vaultPath, "Meetings")
	if err := os.MkdirAll(meetingsDir, 0o755); err != nil {
		return "", fmt.Errorf("create meetings directory: %w", err)
	}

	// Build filename: YYYY-MM-DD-title-slug.md
	slug := slugify(data.Title)
	filename := fmt.Sprintf("%s-%s.md", data.Date, slug)
	filePath := filepath.Join(meetingsDir, filename)

	if err := os.WriteFile(filePath, buf.Bytes(), 0o644); err != nil {
		return "", fmt.Errorf("write file: %w", err)
	}

	log.Printf("[obsidian] Report written to %s", filePath)
	return filePath, nil
}

func buildTemplateData(meeting *models.Meeting) (*templateData, error) {
	data := &templateData{
		Title:    meeting.Title,
		Date:     meeting.Date,
		Duration: formatDuration(meeting.DurationSeconds),
	}

	// Parse summary if available
	if meeting.SummaryJSON != "" {
		var summary summarizer.Summary
		if err := json.Unmarshal([]byte(meeting.SummaryJSON), &summary); err != nil {
			log.Printf("[obsidian] Failed to parse summary JSON: %v", err)
		} else {
			data.Summary = summary.SummaryText
			data.Decisions = summary.Decisions
			data.ActionItems = summary.ActionItems
			data.Topics = summary.Topics
			if summary.Title != "" {
				data.Title = summary.Title
			}
		}
	}

	// Parse transcript for segments and speaker names
	if meeting.TranscriptJSON != "" {
		var transcript struct {
			Segments []struct {
				Speaker string  `json:"speaker"`
				Start   float64 `json:"start"`
				Text    string  `json:"text"`
			} `json:"segments"`
			Speakers []struct {
				ID string `json:"id"`
			} `json:"speakers"`
		}
		if err := json.Unmarshal([]byte(meeting.TranscriptJSON), &transcript); err != nil {
			log.Printf("[obsidian] Failed to parse transcript JSON: %v", err)
		} else {
			for _, s := range transcript.Speakers {
				data.Speakers = append(data.Speakers, s.ID)
			}
			for _, seg := range transcript.Segments {
				data.Segments = append(data.Segments, templateSegment{
					Speaker:   seg.Speaker,
					Timestamp: formatTimestamp(seg.Start),
					Text:      seg.Text,
				})
			}
		}
	}

	return data, nil
}

var nonAlphanumeric = regexp.MustCompile(`[^a-z0-9]+`)

func slugify(s string) string {
	s = strings.ToLower(s)
	s = nonAlphanumeric.ReplaceAllString(s, "-")
	s = strings.Trim(s, "-")
	if len(s) > 50 {
		s = s[:50]
		s = strings.TrimRight(s, "-")
	}
	if s == "" {
		s = "meeting"
	}
	return s
}

func formatDuration(seconds int) string {
	if seconds <= 0 {
		return "0m"
	}
	h := seconds / 3600
	m := (seconds % 3600) / 60
	if h > 0 {
		return fmt.Sprintf("%dh %dm", h, m)
	}
	return fmt.Sprintf("%dm", m)
}

func formatTimestamp(seconds float64) string {
	t := time.Duration(seconds * float64(time.Second))
	m := int(t.Minutes())
	s := int(t.Seconds()) % 60
	return fmt.Sprintf("%d:%02d", m, s)
}
