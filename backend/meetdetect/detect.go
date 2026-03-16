package meetdetect

import (
	"context"
	"log"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Broadcaster sends WebSocket events for Meet detection.
type Broadcaster interface {
	BroadcastJSON(msgType string, payload interface{})
}

// MeetCallback is called when a Google Meet is detected or ended.
type MeetCallback struct {
	OnMeetDetected func(meetURL string)
	OnMeetEnded    func()
}

// Detector polls browser tabs for active Google Meet sessions.
type Detector struct {
	broadcaster Broadcaster
	callback    MeetCallback
	interval    time.Duration

	mu            sync.Mutex
	inMeeting     bool
	currentURL    string
	missCount     int // consecutive polls where Meet was not found
	debounceCount int // number of misses before declaring "ended"
}

// NewDetector creates a Meet detector with 3-second poll interval.
func NewDetector(b Broadcaster, cb MeetCallback) *Detector {
	return &Detector{
		broadcaster:   b,
		callback:      cb,
		interval:      3 * time.Second,
		debounceCount: 2,
	}
}

// Run starts the polling loop. Blocks until context is cancelled.
func (d *Detector) Run(ctx context.Context) {
	log.Printf("[meetdetect] Starting Google Meet detection (interval=%s)", d.interval)
	ticker := time.NewTicker(d.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Printf("[meetdetect] Stopping — context cancelled")
			return
		case <-ticker.C:
			d.poll()
		}
	}
}

// InMeeting returns whether a Meet session is currently active.
func (d *Detector) InMeeting() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.inMeeting
}

// CurrentURL returns the active Meet URL, if any.
func (d *Detector) CurrentURL() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.currentURL
}

var meetURLPattern = regexp.MustCompile(`(?i)https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}`)

type transition int

const (
	transitionNone     transition = iota
	transitionDetected            // not-in-meeting → in-meeting
	transitionEnded               // in-meeting → not-in-meeting
)

func (d *Detector) poll() {
	url := detectMeetURL()

	// Determine transition under the lock, then invoke callbacks outside
	var trans transition
	var transURL string

	d.mu.Lock()
	if url != "" {
		d.missCount = 0
		if !d.inMeeting {
			d.inMeeting = true
			d.currentURL = url
			trans = transitionDetected
			transURL = url
		} else if url != d.currentURL {
			d.currentURL = url
			log.Printf("[meetdetect] Meet URL changed: %s", url)
		}
	} else if d.inMeeting {
		d.missCount++
		if d.missCount >= d.debounceCount {
			d.inMeeting = false
			d.currentURL = ""
			d.missCount = 0
			trans = transitionEnded
		}
	}
	d.mu.Unlock()

	// Fire callbacks outside the lock to prevent deadlocks
	switch trans {
	case transitionDetected:
		log.Printf("[meetdetect] Google Meet detected: %s", transURL)
		d.broadcaster.BroadcastJSON("meet:detected", map[string]string{
			"url": transURL,
		})
		if d.callback.OnMeetDetected != nil {
			d.callback.OnMeetDetected(transURL)
		}
	case transitionEnded:
		log.Printf("[meetdetect] Google Meet ended (debounced)")
		d.broadcaster.BroadcastJSON("meet:ended", map[string]string{})
		if d.callback.OnMeetEnded != nil {
			d.callback.OnMeetEnded()
		}
	}
}

// detectMeetURL checks Chrome, Arc, and Safari for active Google Meet tabs.
// Returns the first meet.google.com URL found, or empty string.
func detectMeetURL() string {
	// Check browsers in order of popularity
	browsers := []struct {
		name   string
		script string
	}{
		{"Google Chrome", chromeScript},
		{"Arc", arcScript},
		{"Safari", safariScript},
	}

	for _, b := range browsers {
		url := runAppleScript(b.script)
		if url != "" {
			match := meetURLPattern.FindString(url)
			if match != "" {
				return match
			}
		}
	}
	return ""
}

func runAppleScript(script string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "osascript", "-e", script)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// AppleScript snippets to get URLs from browser tabs.
// Each returns tab URLs separated by newlines.

const chromeScript = `
tell application "System Events"
	if not (exists process "Google Chrome") then return ""
end tell
tell application "Google Chrome"
	repeat with w in windows
		repeat with t in tabs of w
			set tabURL to URL of t
			if tabURL contains "meet.google.com/" then
				return tabURL
			end if
		end repeat
	end repeat
	return ""
end tell
`

const arcScript = `
tell application "System Events"
	if not (exists process "Arc") then return ""
end tell
tell application "Arc"
	repeat with w in windows
		repeat with t in tabs of w
			set tabURL to URL of t
			if tabURL contains "meet.google.com/" then
				return tabURL
			end if
		end repeat
	end repeat
	return ""
end tell
`

const safariScript = `
tell application "System Events"
	if not (exists process "Safari") then return ""
end tell
tell application "Safari"
	repeat with w in windows
		repeat with t in tabs of w
			set tabURL to URL of t
			if tabURL contains "meet.google.com/" then
				return tabURL
			end if
		end repeat
	end repeat
	return ""
end tell
`
