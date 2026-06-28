// Package events tests.
package events

import (
	"testing"
	"time"
)

func TestBus_Publish_NoSubscribers(t *testing.T) {
	bus := NewBus()
	// Não deve panicar nem bloquear.
	bus.Publish(Event{
		EventType:   "ServerStarted",
		ServiceName: "minecraft",
	})
}

func TestBus_Subscribe_AndReceive(t *testing.T) {
	bus := NewBus()
	ch, cancel := bus.Subscribe(nil)
	defer cancel()

	// Publicar evento.
	bus.Publish(Event{
		EventType:   "PlayerJoined",
		ServiceName: "minecraft",
		Stack:       "minecraft",
		Metadata:    map[string]string{"player": "Steve"},
	})

	select {
	case ev := <-ch:
		if ev.EventType != "PlayerJoined" {
			t.Errorf("EventType = %q, esperado PlayerJoined", ev.EventType)
		}
		if ev.Metadata["player"] != "Steve" {
			t.Errorf("Metadata[player] = %q, esperado Steve", ev.Metadata["player"])
		}
		if ev.EventID == "" {
			t.Error("EventID não foi gerado automaticamente")
		}
		if ev.TimestampUnix == 0 {
			t.Error("TimestampUnix não foi setado automaticamente")
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando evento")
	}
}

func TestBus_Subscribe_WithFilter(t *testing.T) {
	bus := NewBus()
	ch, cancel := bus.Subscribe([]string{"PlayerJoined"})
	defer cancel()

	// Publicar evento NÃO filtrado — não deve chegar.
	bus.Publish(Event{EventType: "ServerStarted", ServiceName: "minecraft"})
	// Publicar evento filtrado — deve chegar.
	bus.Publish(Event{EventType: "PlayerJoined", ServiceName: "minecraft"})

	select {
	case ev := <-ch:
		if ev.EventType != "PlayerJoined" {
			t.Errorf("recebido EventType %q, esperado PlayerJoined", ev.EventType)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout esperando PlayerJoined")
	}

	// Próximo evento NÃO deve existir (ServerStarted foi filtrado).
	select {
	case ev := <-ch:
		t.Errorf("recebido evento não-esperado: %+v", ev)
	case <-time.After(100 * time.Millisecond):
		// OK
	}
}

func TestBus_MultipleSubscribers(t *testing.T) {
	bus := NewBus()
	ch1, cancel1 := bus.Subscribe(nil)
	defer cancel1()
	ch2, cancel2 := bus.Subscribe(nil)
	defer cancel2()

	bus.Publish(Event{EventType: "ServerStarted", ServiceName: "minecraft"})

	for i, ch := range []<-chan Event{ch1, ch2} {
		select {
		case <-ch:
			// OK
		case <-time.After(time.Second):
			t.Errorf("subscriber %d não recebeu evento", i)
		}
	}
}

func TestBus_Cancel(t *testing.T) {
	bus := NewBus()
	_, cancel := bus.Subscribe(nil)
	cancel()
	// Não deve panicar.
	bus.Publish(Event{EventType: "ServerStarted"})
	if bus.SubscriberCount() != 0 {
		t.Errorf("esperado 0 subscribers após cancel, obtido %d", bus.SubscriberCount())
	}
}

func TestBus_SlowSubscriberDoesNotBlock(t *testing.T) {
	bus := NewBus()
	// Cria subscriber sem ler nada (buffer 64 enche rapidamente).
	ch, cancel := bus.Subscribe(nil)
	defer cancel()

	// Publicar 100 eventos — buffer é 64, então ~36 serão descartados.
	for i := 0; i < 100; i++ {
		bus.Publish(Event{
			EventType:   "ConsoleOutput",
			ServiceName: "minecraft",
			Metadata:    map[string]string{"i": "x"},
		})
	}

	// Deve ter pelo menos 64 no buffer.
	received := 0
drainLoop:
	for {
		select {
		case <-ch:
			received++
		default:
			break drainLoop
		}
	}
	if received > 64 {
		t.Errorf("recebido %d, esperado <= 64 (buffer)", received)
	}
}
