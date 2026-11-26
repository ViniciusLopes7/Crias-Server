package ui

import (
	"strings"
	"testing"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestHardwarePaginationAndStates(t *testing.T) {
	s := metrics.Snapshot{}
	s.Hardware.Sensors.State = metrics.Available
	for i := 0; i < 25; i++ {
		s.Hardware.Sensors.Data.Values = append(s.Hardware.Sensors.Data.Values, metrics.Sensor{
			ID: "hwmon0", Label: "bad\x1b\nlabel", Value: metrics.Sample{State: metrics.Available, Unit: metrics.RPM, Value: 0},
		})
	}
	state := app.New().Resize(60, 20)
	state.Tab, state.Detail = 2, true
	found := 0
	for page := 0; page < HardwarePages(s); page++ {
		got := Render(state, Options{ASCII: true, Telemetry: &s, Monitor: MonitorView{HardwarePage: page}})
		if strings.Contains(got, "\x1b") || lipgloss.Width(got) > 59 || lipgloss.Height(got) > 20 {
			t.Fatal("unsafe or overflowing view", got)
		}
		found += strings.Count(got, "bad??label")
	}
	if found != 25 {
		t.Fatal("not all sensors reachable", found)
	}
	s.Hardware.Sensors.State = metrics.Stale
	if strings.Contains(strings.Join(func() []string {
		var out []string
		for _, row := range hardwareRows(s) {
			out = append(out, row.text)
		}
		return out
	}(), "\n"), "bad??label") {
		t.Fatal("stale sensor shown as current")
	}
}

func TestHistoryAndProfileView(t *testing.T) {
	m := MonitorView{Profile: metrics.Economy, Window: 5 * time.Minute, CPU: metrics.Stats{Count: 2, Min: 10, Mean: 20, Max: 30, Gap: true}}
	state := app.New().Resize(80, 24)
	s := metrics.Snapshot{}
	got := Render(state, Options{Telemetry: &s, Monitor: m})
	for _, want := range []string{"Histórico 5 min", "10.0/20.0/30.0%", "lacunas", "RAM: sem amostras válidas"} {
		if !strings.Contains(got, want) {
			t.Fatal("missing", want, got)
		}
	}
	state.Tab = 5
	got = Render(state, Options{Telemetry: &s, Monitor: m})
	if !strings.Contains(got, "Econômico") || !strings.Contains(got, "CPU/RAM: 3s") {
		t.Fatal(got)
	}
}
