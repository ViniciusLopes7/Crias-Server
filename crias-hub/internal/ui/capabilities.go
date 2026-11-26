package ui

import (
	"fmt"
	"strings"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func capabilityText(c metrics.Capability) string {
	if c.Group != metrics.Available {
		return c.Name + ": " + availability(c.Group)
	}
	var parts []string
	for _, v := range []struct {
		n     int
		label string
	}{
		{c.Observed, "lidos"},
		{c.Estimated, "estimados"},
		{c.Waiting, "aguardando"},
		{c.Denied, "sem permissão"},
		{c.Invalid, "inválidos"},
		{c.Stale, "obsoletos"},
		{c.Missing, "indisponíveis"},
	} {
		if v.n > 0 {
			parts = append(parts, fmt.Sprintf("%d %s", v.n, v.label))
		}
	}
	if len(parts) == 0 {
		return c.Name + ": nenhum canal identificado"
	}
	return c.Name + ": " + strings.Join(parts, " / ")
}

func capabilityRows(h metrics.HardwareSnapshot) []line {
	rows := []line{{"Capacidades de leitura", heading}, {"Controles: não validados / bloqueados", muted}}
	for _, c := range metrics.Capabilities(h) {
		for _, part := range wrapHardware(capabilityText(c)) {
			rows = append(rows, line{part, normal})
		}
	}
	return rows
}
