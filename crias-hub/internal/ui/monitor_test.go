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
	for _, row := range hardwareRows(s) {
		if strings.Contains(row.text, "bad??label") {
			t.Fatal("stale sensor shown as current")
		}
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

func TestHardwareWrapAndEntryHint(t *testing.T) {
	state := app.New().Resize(60, 20)
	state.Tab = 2
	s := metrics.Snapshot{}
	s.Hardware.Sensors.State = metrics.Available
	s.Hardware.Sensors.Data.Values = []metrics.Sensor{{
		ID: "hwmon0", Label: strings.Repeat("x", 120),
		Value: metrics.Sample{State: metrics.Available, Unit: metrics.Celsius, Value: 42.5},
	}}
	if !strings.Contains(Render(state, Options{ASCII: true, Telemetry: &s}), "Enter: detalhes de hardware") {
		t.Fatal("detail entry hidden at minimum terminal")
	}
	state.Detail = true
	var all strings.Builder
	for page := 0; page < HardwarePages(s); page++ {
		got := Render(state, Options{ASCII: true, Telemetry: &s, Monitor: MonitorView{HardwarePage: page}})
		all.WriteString(got)
	}
	if !strings.Contains(all.String(), "42.5") || !strings.Contains(all.String(), "graus C") {
		t.Fatal("wrapped reading lost", all.String())
	}
}
