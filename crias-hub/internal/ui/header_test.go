package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestHardwareHeaderScopeAndFreshness(t *testing.T) {
	s := metrics.Snapshot{}
	sample := func(n float64, unit metrics.Unit) metrics.Sample {
		return metrics.Sample{Value: n, Unit: unit, State: metrics.Available}
	}
	h := &s.Hardware
	h.Sensors.State = metrics.Available
	h.Sensors.Data.Values = []metrics.Sensor{
		{Driver: "amdgpu", Label: "edge", Value: sample(95, metrics.Celsius)},
		{Driver: "k10temp", Label: "Tctl", Value: sample(80, metrics.Celsius)},
		{Driver: "k10temp", Label: "Tdie", Value: sample(54, metrics.Celsius)},
		{Driver: "k10temp", Label: "Tdie", Value: sample(58, metrics.Celsius)},
	}
	h.Domains.State = metrics.Available
	h.Domains.Data.Values = []metrics.PowerDomain{
		{Name: "package-0", NameState: metrics.Available, Average: sample(12, metrics.Watts)},
		{Name: "core", NameState: metrics.Available, Instant: sample(6, metrics.Watts)},
	}
	h.Supplies.State = metrics.Available
	h.Supplies.Data.Batteries = []metrics.Battery{{Capacity: sample(80, metrics.Percent)}}
	state := app.New().Resize(60, 20)
	got := Render(state, Options{Telemetry: &s})
	for _, want := range []string{"CPU Tdie máx: 58.0°C", "Bat: 80.0%", "Pot. pacote CPU: 12.0 W (média)"} {
		if !strings.Contains(got, want) {
			t.Fatal("missing", want, got)
		}
	}
	for _, bad := range []string{"95.0°C", "80.0°C", "18.0 W"} {
		if strings.Contains(got, bad) {
			t.Fatal("wrong scope", bad, got)
		}
	}
	h.Domains.Data.Values = append(h.Domains.Data.Values, metrics.PowerDomain{Name: "package-1", NameState: metrics.Available, Instant: sample(9, metrics.Watts)})
	h.Supplies.Data.Batteries = append(h.Supplies.Data.Batteries, metrics.Battery{Capacity: sample(30, metrics.Percent)})
	h.Sensors.State = metrics.Stale
	got = Render(state, Options{Telemetry: &s})
	for _, want := range []string{"Temp CPU: obsoleto", "Bat: múltiplas", "múltiplos (ver Hardware)"} {
		if !strings.Contains(got, want) {
			t.Fatal("missing", want, got)
		}
	}
	for _, bad := range []string{"58.0°C", "80.0%", "12.0 W"} {
		if strings.Contains(got, bad) {
			t.Fatal("stale or ambiguous value", bad, got)
		}
	}
}

func TestHardwareHeaderLayout(t *testing.T) {
	s := metrics.Snapshot{}
	s.Hardware.Sensors.State = metrics.Permission
	s.Hardware.Domains.State = metrics.Stale
	s.Hardware.Supplies.State = metrics.Permission
	for _, size := range [][2]int{{60, 20}, {80, 24}, {120, 40}, {40, 12}} {
		state := app.New().Resize(size[0], size[1])
		state.Tab, state.Detail = 2, true
		for _, ascii := range []bool{false, true} {
			got := Render(state, Options{ASCII: ascii, Telemetry: &s})
			if lipgloss.Width(got) > size[0]-1 || lipgloss.Height(got) > size[1] {
				t.Fatal("overflow", size, got)
			}
			if size[0] >= 60 && !strings.Contains(got, "Hardware 1/") {
				t.Fatal("hardware detail hidden", got)
			}
		}
	}
}

func TestPackagePowerDiagnosticParity(t *testing.T) {
	for _, tc := range []struct {
		instant, average metrics.Sample
		want             string
	}{
		{metrics.Sample{State: metrics.Permission}, metrics.Sample{State: metrics.Unavailable}, "sem permissão"},
		{metrics.Sample{State: metrics.Invalid}, metrics.Sample{State: metrics.Waiting}, "inválido"},
		{metrics.Sample{State: metrics.Available, Unit: metrics.MHz}, metrics.Sample{State: metrics.Unavailable}, "inválido"},
		{metrics.Sample{State: metrics.Stale}, metrics.Sample{State: metrics.Waiting}, "obsoleto"},
		{metrics.Sample{State: metrics.Permission}, metrics.Sample{State: metrics.Available, Unit: metrics.Watts, Value: 10}, "10.0 W (média)"},
		{metrics.Sample{State: metrics.Estimated, Unit: metrics.Watts, Value: 8}, metrics.Sample{State: metrics.Unavailable}, "~8.0 W (instant.)"},
	} {
		r := metrics.Reading[metrics.PowerDomains]{
			State: metrics.Available,
			Data: metrics.PowerDomains{Values: []metrics.PowerDomain{{
				Name: "package-0", NameState: metrics.Available,
				Instant: tc.instant, Average: tc.average,
			}}},
		}
		if got := packagePower(r); got != "Pot. pacote CPU: "+tc.want {
			t.Fatalf("got %q, want %q", got, tc.want)
		}
	}
}
