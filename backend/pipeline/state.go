package pipeline

import (
	"fmt"
	"sync"
)

// State represents the current pipeline state.
type State string

const (
	StateIdle       State = "idle"
	StateRecording  State = "recording"
	StateProcessing State = "processing"
	StateDone       State = "done"
	StateError      State = "error"
)

// validTransitions defines which state transitions are allowed.
var validTransitions = map[State][]State{
	StateIdle:       {StateRecording},
	StateRecording:  {StateProcessing, StateIdle, StateError},
	StateProcessing: {StateDone, StateError},
	StateDone:       {StateIdle},
	StateError:      {StateIdle},
}

// Pipeline is a thread-safe state machine for the recording pipeline.
type Pipeline struct {
	mu        sync.RWMutex
	state     State
	meetingID string
}

// New creates a Pipeline in the idle state.
func New() *Pipeline {
	return &Pipeline{
		state: StateIdle,
	}
}

// GetState returns the current pipeline state and meeting ID.
func (p *Pipeline) GetState() (State, string) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	return p.state, p.meetingID
}

// StartRecording transitions from idle to recording.
func (p *Pipeline) StartRecording(meetingID string) error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if err := p.validateTransition(StateRecording); err != nil {
		return err
	}
	p.state = StateRecording
	p.meetingID = meetingID
	return nil
}

// StopRecording transitions from recording to processing (or idle if no processing needed).
func (p *Pipeline) StopRecording() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if err := p.validateTransition(StateProcessing); err != nil {
		// Allow direct transition to idle as well
		if err2 := p.validateTransition(StateIdle); err2 != nil {
			return err
		}
		p.state = StateIdle
		p.meetingID = ""
		return nil
	}
	p.state = StateProcessing
	return nil
}

// MarkDone transitions from processing to done, then resets to idle.
func (p *Pipeline) MarkDone() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if err := p.validateTransition(StateDone); err != nil {
		return err
	}
	p.state = StateDone
	return nil
}

// Reset transitions back to idle from done or error.
func (p *Pipeline) Reset() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if err := p.validateTransition(StateIdle); err != nil {
		return err
	}
	p.state = StateIdle
	p.meetingID = ""
	return nil
}

// SetError transitions to the error state from recording or processing.
func (p *Pipeline) SetError() error {
	p.mu.Lock()
	defer p.mu.Unlock()

	if err := p.validateTransition(StateError); err != nil {
		return err
	}
	p.state = StateError
	return nil
}

// validateTransition checks if moving to target is allowed from the current state.
// Must be called with the lock held.
func (p *Pipeline) validateTransition(target State) error {
	allowed := validTransitions[p.state]
	for _, s := range allowed {
		if s == target {
			return nil
		}
	}
	return fmt.Errorf("invalid transition from %s to %s", p.state, target)
}
