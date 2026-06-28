// Package events implementa um bus de eventos em memória com fan-out
// para múltiplos subscribers (clients gRPC conectados ao SubscribeEvents).
package events

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

// Event é um evento emitido pelo agente (ServerStarted, PlayerJoined, etc.).
type Event struct {
	EventID       string            `json:"event_id"`
	EventType     string            `json:"event_type"`
	TimestampUnix int64             `json:"timestamp_unix"`
	ServiceName   string            `json:"service_name"`
	Stack         string            `json:"stack"`
	Metadata      map[string]string `json:"metadata"`
}

// Bus é um bus de eventos em memória com suporte a múltiplos subscribers.
type Bus struct {
	mu          sync.RWMutex
	subscribers map[string]chan Event
}

// NewBus cria um novo bus de eventos.
func NewBus() *Bus {
	return &Bus{
		subscribers: make(map[string]chan Event),
	}
}

// Subscribe registra um novo subscriber. Retorna o canal de eventos e
// uma função de cancelamento (unsubscribe).
// O canal tem buffer de 64 eventos; eventos extras são descartados (não bloqueia o emitter).
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

	// Se houver filtro, wrap o canal com um filtro.
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
						// descarta se subscriber está lento
					}
				}
			}
			close(filteredCh)
		}()
		return filteredCh, cancel
	}

	return ch, cancel
}

// Publish emite um evento para todos os subscribers.
// Non-blocking: se um subscriber não tem buffer, o evento é descartado.
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
			// subscriber lento — descarta evento para não bloquear o agente
		}
	}
}

// SubscriberCount retorna o número de subscribers ativos (para debug).
func (b *Bus) SubscriberCount() int {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return len(b.subscribers)
}
