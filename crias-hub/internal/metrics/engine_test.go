package metrics

import (
	"context"
	"io/fs"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"
)

func TestHistoryRetentionAndGaps(t *testing.T) {
	var h history
	start := time.Unix(10000, 0)
	for i := 0; i < historyCapacity+10; i++ {
		at := start.Add(time.Duration(i) * 500 * time.Millisecond)
		h.add(observed(20, Percent, "fixture", "host", at), 500*time.Millisecond)
	}
	now := start.Add(time.Duration(historyCapacity+9) * 500 * time.Millisecond)
	if h.size != historyCapacity {
		t.Fatal("ring not bounded", h.size)
	}
	s := h.summarize(now, time.Hour)
	if s.Count != historyCapacity || s.Min != 20 || s.Max != 20 || s.Mean != 20 || s.Gap {
		t.Fatalf("history: %+v", s)
	}
	h.add(missing(Permission, Percent, "fixture", "host", now.Add(time.Second)), time.Second)
	h.add(observed(80, Percent, "fixture", "host", now.Add(10*time.Second)), time.Second)
	s = h.summarize(now.Add(10*time.Second), time.Minute)
	if s.Missing != 1 || !s.Gap || s.Max != 80 || s.Min != 20 || s.Mean <= 20 || s.Mean >= 80 {
		t.Fatalf("gap/statistics: %+v", s)
	}
	if got := h.summarize(now.Add(2*time.Hour), time.Hour); got.Count != 0 || !got.Gap {
		t.Fatal("expired data returned", got)
	}
	if got := h.summarize(now, 2*time.Hour); got.Count != 0 {
		t.Fatal("unapproved window accepted", got)
	}
}

type blockingProc struct {
	entered chan struct{}
	release chan struct{}
	calls   atomic.Int32
}

func (b *blockingProc) Open(name string) (fs.File, error) {
	if name == "stat" {
		if b.calls.Add(1) == 1 {
			close(b.entered)
		}
		<-b.release
		return fixture("stat", "cpu 1 0 1 2\n").Open(name)
	}
	return fixture("meminfo", "MemTotal: 100 kB\nMemAvailable: 40 kB\n").Open(name)
}

func await(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out")
	}
}

func TestIndependentWorkersAndCancellation(t *testing.T) {
	b := &blockingProc{entered: make(chan struct{}), release: make(chan struct{})}
	e := NewEngine(context.Background(), b)
	defer e.Stop()
	released := false
	defer func() {
		if !released {
			close(b.release)
		}
	}()
	await(t, b.entered)
	await(t, e.Changed())
	s := e.Snapshot(time.Now())
	if s.CPU.State != Waiting || s.Memory.Usage.Value != 60 || !s.Memory.Usage.Valid() {
		t.Fatalf("blocked CPU impeded memory: %+v", s)
	}
	// An overdue observation is stale, not a new reading or zero.
	if e.Snapshot(time.Now().Add(10*time.Second)).Memory.Usage.State != Stale {
		t.Fatal("freshness not enforced")
	}
	if !e.SetProfile(Detailed) || e.SetProfile(Profile(255)) {
		t.Fatal("profile validation")
	}
	e.Stop()
	if b.calls.Load() != 1 {
		t.Fatal("overlapping CPU collector")
	}
	// Stop cannot terminate a blocking kernel read. Release the fixture
	// before waiting for the worker to exit.
	select {
	case <-e.Done():
		t.Fatal("reported shutdown while a worker is blocked")
	default:
	}
	close(b.release)
	released = true
	await(t, e.Done())
}

func TestEngineShutdownAndCoalescing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	proc := fstest.MapFS{
		"stat":    {Data: []byte("cpu 1 0 1 2\n")},
		"meminfo": {Data: []byte("MemTotal: 100 kB\nMemAvailable: 40 kB\n")},
	}
	e := NewEngine(ctx, proc)
	defer e.Stop()
	await(t, e.Changed())
	deadline := time.After(3 * time.Second)
	for !e.Snapshot(time.Now()).Memory.Usage.Valid() {
		select {
		case <-e.Changed():
		case <-deadline:
			t.Fatal("memory not published")
		}
	}
	_, mem := e.History(time.Now(), time.Minute)
	if mem.Count != 1 || mem.Mean != 60 {
		t.Fatal("unexpected history", mem)
	}
	cancel()
	await(t, e.Done())
	e.Stop()
}
