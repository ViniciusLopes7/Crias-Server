package ui

import (
	"strings"
	"testing"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func TestCapabilityPagination(t *testing.T) {
	s := metrics.Snapshot{}
	s.Hardware.Sensors.State = metrics.Available
	s.Hardware.Sensors.Data.Values = []metrics.Sensor{
		{Value: metrics.Sample{Unit: metrics.RPM, State: metrics.Available}},
		{Value: metrics.Sample{Unit: metrics.RPM, State: metrics.Permission}},
	}
	state := app.New().Resize(60, 20)
	state.Tab, state.Detail = 2, true
	var all strings.Builder
	for page := 0; page < HardwarePages(s); page++ {
		all.WriteString(Render(state, Options{ASCII: true, Telemetry: &s, Monitor: MonitorView{HardwarePage: page}}))
	}
	for _, want := range []string{"Capacidades de leitura", "Controles: nao validados / bloqueados", "Ventoinhas RPM: 1 lidos / 1 sem permissao", "Temperatura hwmon: nenhum canal identificado"} {
		if !strings.Contains(all.String(), want) {
			t.Fatal("missing", want, all.String())
		}
	}
}
