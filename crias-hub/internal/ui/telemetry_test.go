package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestTelemetryRender(t *testing.T) {
	snapshot := metrics.Snapshot{
		CPU: metrics.Sample{Value: 25, Unit: metrics.Percent, State: metrics.Available},
		Memory: metrics.Memory{
			Used: metrics.Sample{Value: 1024 * 1048576, Unit: metrics.Bytes, State: metrics.Available},
		},
	}
	state := app.New().Resize(120, 40)
	got := Render(state, Options{Telemetry: &snapshot})
	for _, want := range []string{"CRIAS HUB | C03", "CPU host: 25.0%", "RAM host: 1024 MiB", "não é heap JVM"} {
		if !strings.Contains(got, want) {
			t.Fatal("missing", want, got)
		}
	}
	snapshot.CPU.State = metrics.Stale
	snapshot.Memory.Used.State = metrics.Permission
	got = Render(state, Options{Telemetry: &snapshot})
	if !strings.Contains(got, "CPU host: obsoleto") || !strings.Contains(got, "RAM host: sem permissão") || strings.Contains(got, "1024 MiB") {
		t.Fatal("unavailable values rendered as current", got)
	}
	for _, size := range [][2]int{{120, 40}, {80, 24}, {60, 20}, {20, 5}, {1, 1}} {
		state = state.Resize(size[0], size[1])
		state.Tab = 2
		got = Render(state, Options{ASCII: true, Telemetry: &snapshot})
		if lipgloss.Width(got) > size[0]-1 || lipgloss.Height(got) > size[1] {
			t.Fatal("telemetry overflow", size, got)
		}
		for _, r := range got {
			if r > 127 {
				t.Fatal("non-ASCII output", r)
			}
		}
	}
}
