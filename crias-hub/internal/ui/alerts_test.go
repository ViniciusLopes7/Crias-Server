package ui

import (
	"strings"
	"testing"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestThermalSummary(t *testing.T) {
	s := metrics.Snapshot{}
	r := &s.Hardware.Sensors
	r.State = metrics.Available
	r.Data.Values = []metrics.Sensor{
		{Alert: metrics.ThermalCritical, Value: metrics.Sample{State: metrics.Available, Unit: metrics.Celsius}},
		{Alert: metrics.ThermalWarning, Value: metrics.Sample{State: metrics.Available, Unit: metrics.Celsius}},
		{Alert: metrics.ThermalNormal, Value: metrics.Sample{State: metrics.Available, Unit: metrics.Celsius}},
		{Alert: metrics.ThermalCritical, Value: metrics.Sample{State: metrics.Invalid, Unit: metrics.Celsius}},
	}
	state := app.New().Resize(60, 20)
	got := Render(state, Options{Telemetry: &s, ASCII: true})
	if !strings.Contains(got, "Termico: 1 crit | 1 alertas | 3 avaliados") {
		t.Fatal(got)
	}
	r.State = metrics.Stale
	got = Render(state, Options{Telemetry: &s})
	if !strings.Contains(got, "Térmico: obsoleto") || strings.Contains(got, "1 crít") {
		t.Fatal(got)
	}
}
