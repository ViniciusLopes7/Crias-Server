package main

import (
	"time"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/ui"
)

// These local shortcuts are available only in their visible telemetry
// views. Global navigation and search/help input keep their old semantics.
func (m *model) monitorKey(key string) bool {
	if m.engine == nil || m.snapshot == nil || m.state.Overlay != app.OverlayNone ||
		m.state.Width < 60 || m.state.Height < 20 || m.state.Focus == app.FocusContext {
		return false
	}
	switch {
	case m.state.Tab == 5 && (key == "p" || key == "P"):
		next := (m.monitor.Profile + 1) % 3
		if m.engine.SetProfile(next) {
			m.monitor.Profile = next
		}
		return true
	case m.state.Tab == 0 && (key == "h" || key == "H"):
		switch m.monitor.Window {
		case time.Minute:
			m.monitor.Window = 5 * time.Minute
		case 5 * time.Minute:
			m.monitor.Window = 15 * time.Minute
		case 15 * time.Minute:
			m.monitor.Window = time.Hour
		default:
			m.monitor.Window = time.Minute
		}
		m.refreshMonitor()
		return true
	case m.state.Tab == 2 && m.state.Detail && (key == "up" || key == "down"):
		pages := ui.HardwarePages(*m.snapshot)
		delta := 1
		if key == "up" {
			delta = -1
		}
		m.monitor.HardwarePage = (m.monitor.HardwarePage + delta + pages) % pages
		return true
	}
	return false
}

func (m *model) refreshMonitor() {
	if m.engine == nil || m.snapshot == nil {
		return
	}
	m.monitor.HardwarePage = min(m.monitor.HardwarePage, ui.HardwarePages(*m.snapshot)-1)
	if m.state.Tab == 0 && m.state.Overlay == app.OverlayNone {
		if m.monitor.Window == 0 {
			m.monitor.Window = time.Minute
		}
		m.monitor.CPU, m.monitor.RAM = m.engine.History(time.Now(), m.monitor.Window)
	}
}
