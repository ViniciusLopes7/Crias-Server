package ui

import (
	"strings"
	"testing"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestServiceView(t *testing.T) {
	s := metrics.Snapshot{}
	s.Services.State = metrics.Available
	s.Services.Data = []metrics.ServiceStatus{
		{Unit: "minecraft.service", Load: "loaded", Active: "active", Sub: "running", State: metrics.Available},
		{Unit: "terraria.service", Load: "not-found", Active: "inactive", Sub: "dead", State: metrics.Available},
		{Unit: "sshd.service", State: metrics.Permission},
		{Unit: "tailscaled.service", Load: "loaded", Active: "failed", Sub: "failed", State: metrics.Available},
	}
	state := app.New().Resize(60, 20)
	state.Tab = 4
	got := Render(state, Options{Telemetry: &s})
	for _, want := range []string{"minecraft.service: loaded / active / running", "terraria.service: not-found / inactive / dead", "sshd.service: sem permissão", "tailscaled.service: loaded / failed / failed", "Ativo não confirma"} {
		if !strings.Contains(got, want) {
			t.Fatal("missing", want, got)
		}
	}
	s.Services.State = metrics.Stale
	got = Render(state, Options{Telemetry: &s})
	if strings.Contains(got, "running") || !strings.Contains(got, "obsoleto") {
		t.Fatal("stale service exposed", got)
	}
}
