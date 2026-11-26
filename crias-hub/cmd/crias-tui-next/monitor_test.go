package main

import (
	"context"
	"testing"
	"testing/fstest"
	"time"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/ui"
)

func TestMonitorKeysAndOverlayIsolation(t *testing.T) {
	e := metrics.NewEngine(context.Background(), fstest.MapFS{})
	defer func() {
		e.Stop()
		select {
		case <-e.Done():
		case <-time.After(3 * time.Second):
			t.Error("engine did not stop")
		}
	}()
	s := e.Snapshot(time.Now())
	m := model{state: app.New(), engine: e, snapshot: &s, monitor: ui.MonitorView{Window: time.Minute}}
	for _, want := range []time.Duration{5 * time.Minute, 15 * time.Minute, time.Hour, time.Minute} {
		if !m.monitorKey("h") || m.monitor.Window != want {
			t.Fatal("history window not changed", m.monitor.Window)
		}
	}
	m.state.Tab = 5
	for _, want := range []metrics.Profile{metrics.Economy, metrics.Detailed, metrics.Balanced} {
		if !m.monitorKey("p") || m.monitor.Profile != want {
			t.Fatal("profile not changed", m.monitor.Profile)
		}
	}
	m.state.Overlay = app.OverlaySearch
	if m.monitorKey("p") || m.monitor.Profile != metrics.Balanced {
		t.Fatal("profile shortcut leaked into search")
	}
	m.state.Overlay = app.OverlayNone
	m.state = m.state.Resize(40, 15)
	if m.monitorKey("p") {
		t.Fatal("hidden shortcut active")
	}
}
