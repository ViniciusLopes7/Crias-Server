// Package events implements an in-memory event bus with fan-out to multiple subscribers
// (gRPC clients connected to SubscribeEvents).
package events

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// Event is an agent-emitted event (ServerStarted, PlayerJoined, etc.).
type Event struct {
	EventID       string            `json:"event_id"`
	EventType     string            `json:"event_type"`
	TimestampUnix int64             `json:"timestamp_unix"`
	ServiceName   string            `json:"service_name"`
	Stack         string            `json:"stack"`
	Metadata      map[string]string `json:"metadata"`
}

// Bus is an in-memory event bus supporting multiple subscribers.
type Bus struct {
	mu          sync.RWMutex
	subscribers map[string]chan Event
}

// NewBus creates a new event bus.
func NewBus() *Bus {
	return &Bus{
		subscribers: make(map[string]chan Event),
	}
}

// Subscribe registers a subscriber and returns the event channel plus an unsubscribe function.
// The channel is buffered with 64 events; extras are dropped (non-blocking for the emitter).
func (b *Bus) Subscribe(filter []string) (<-chan Event, func()) {
	b.mu.Lock()
	defer b.mu.Unlock()

	id := uuid.NewString()
	ch := make(chan Event, 64)
	b.subscribers[id] = ch

	cancel := func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		if c, ok := b.subscribers[id]; ok {
			close(c)
			delete(b.subscribers, id)
		}
	}

	// If a filter is set, wrap the channel with a filter goroutine.
	if len(filter) > 0 {
		filterSet := make(map[string]bool, len(filter))
		for _, t := range filter {
			filterSet[t] = true
		}
		filteredCh := make(chan Event, 64)
		go func() {
			for ev := range ch {
				if filterSet[ev.EventType] {
					select {
					case filteredCh <- ev:
					default:
						// drop if the subscriber is slow
					}
				}
			}
			close(filteredCh)
		}()
		return filteredCh, cancel
	}

	return ch, cancel
}

// Publish emits an event to all subscribers.
// Non-blocking: events are dropped if a subscriber's buffer is full.
func (b *Bus) Publish(ev Event) {
	if ev.EventID == "" {
		ev.EventID = uuid.NewString()
	}
	if ev.TimestampUnix == 0 {
		ev.TimestampUnix = time.Now().Unix()
	}

	b.mu.RLock()
	defer b.mu.RUnlock()

	for _, ch := range b.subscribers {
		select {
		case ch <- ev:
		default:
			// slow subscriber — drop the event to avoid blocking the agent
		}
	}
}

// SubscriberCount returns the number of active subscribers (for debugging).
func (b *Bus) SubscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subscribers)
}
