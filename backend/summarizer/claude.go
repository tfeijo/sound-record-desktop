package summarizer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	apiURL     = "https://api.anthropic.com/v1/messages"
	apiVersion = "2023-06-01"
	model      = "claude-sonnet-4-20250514"
	maxTokens  = 4096
)

// Summary is the structured output from Claude's meeting summarization.
type Summary struct {
	Title       string       `json:"title"`
	SummaryText string       `json:"summary"`
	Decisions   []string     `json:"decisions"`
	ActionItems []ActionItem `json:"action_items"`
	Topics      []Topic      `json:"topics"`
}

// ActionItem represents a task identified in the meeting.
type ActionItem struct {
	Description string `json:"description"`
	Assignee    string `json:"assignee"`
}

// Topic represents a discussion topic from the meeting.
type Topic struct {
	Title   string `json:"title"`
	Summary string `json:"summary"`
}

// apiRequest is the Anthropic Messages API request body.
type apiRequest struct {
	Model     string       `json:"model"`
	MaxTokens int          `json:"max_tokens"`
	System    string       `json:"system"`
	Messages  []apiMessage `json:"messages"`
}

type apiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// apiResponse is the Anthropic Messages API response body.
type apiResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	StopReason string `json:"stop_reason"`
	Error      *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// Client calls the Anthropic API to summarize meeting transcripts.
type Client struct {
	apiKey     string
	httpClient *http.Client
}

// NewClient creates a summarizer Client. Reads ANTHROPIC_API_KEY from env.
func NewClient() *Client {
	return &Client{
		apiKey: os.Getenv("ANTHROPIC_API_KEY"),
		httpClient: &http.Client{
			Timeout: 2 * time.Minute,
		},
	}
}

// Available returns true if the API key is configured.
func (c *Client) Available() bool {
	return c.apiKey != ""
}

// Summarize sends a transcript to Claude and returns a structured Summary.
func (c *Client) Summarize(ctx context.Context, transcript string) (*Summary, error) {
	if !c.Available() {
		return nil, fmt.Errorf("ANTHROPIC_API_KEY not set")
	}

	reqBody := apiRequest{
		Model:     model,
		MaxTokens: maxTokens,
		System:    systemPrompt,
		Messages: []apiMessage{
			{Role: "user", Content: buildUserPrompt(transcript)},
		},
	}

	bodyBytes, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(bodyBytes))
	if err != nil {
		return nil, fmt.Errorf("create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", c.apiKey)
	req.Header.Set("anthropic-version", apiVersion)

	log.Printf("[summarizer] Calling Claude API (model=%s)", model)
	startTime := time.Now()

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("api call failed: %w", err)
	}
	defer resp.Body.Close()

	respBytes, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1 MB cap
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}

	elapsed := time.Since(startTime)
	log.Printf("[summarizer] Claude API responded in %s (status=%d)", elapsed.Round(time.Millisecond), resp.StatusCode)

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("api error (status %d): %s", resp.StatusCode, string(respBytes))
	}

	var apiResp apiResponse
	if err := json.Unmarshal(respBytes, &apiResp); err != nil {
		return nil, fmt.Errorf("unmarshal api response: %w", err)
	}

	if apiResp.Error != nil {
		return nil, fmt.Errorf("api error: %s - %s", apiResp.Error.Type, apiResp.Error.Message)
	}

	if len(apiResp.Content) == 0 {
		return nil, fmt.Errorf("empty response from Claude")
	}

	if apiResp.StopReason == "max_tokens" {
		return nil, fmt.Errorf("response truncated (max_tokens reached) — try a shorter transcript or increase maxTokens")
	}

	// Parse the JSON from Claude's text response
	text := apiResp.Content[0].Text
	// Strip markdown code fences if Claude wraps the JSON
	text = strings.TrimSpace(text)
	text = strings.TrimPrefix(text, "```json")
	text = strings.TrimPrefix(text, "```")
	text = strings.TrimSuffix(text, "```")
	text = strings.TrimSpace(text)
	var summary Summary
	if err := json.Unmarshal([]byte(text), &summary); err != nil {
		return nil, fmt.Errorf("parse summary json: %w (raw: %.500s)", err, text)
	}

	log.Printf("[summarizer] Summary generated: title=%q, %d decisions, %d action items, %d topics",
		summary.Title, len(summary.Decisions), len(summary.ActionItems), len(summary.Topics))

	return &summary, nil
}

