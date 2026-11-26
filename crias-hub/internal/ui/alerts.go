package ui

import (
	"fmt"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func thermalLabel(a metrics.ThermalAlert) string {
	switch a {
	case metrics.ThermalCritical:
		return "crítico"
	case metrics.ThermalWarning:
		return "atenção"
	case metrics.ThermalNormal:
		return "abaixo dos limites avaliados"
	default:
		return "não avaliado"
	}
}

func thermalSummary(r metrics.Reading[metrics.Sensors]) string {
	if r.State != metrics.Available {
		return "Térmico: " + availability(r.State)
	}
	checked, warning, critical := 0, 0, 0
	for _, v := range r.Data.Values {
		if !v.Value.Valid() || v.Value.Unit != metrics.Celsius {
			continue
		}
		switch v.Alert {
		case metrics.ThermalNormal:
			checked++
		case metrics.ThermalWarning:
			checked++
			warning++
		case metrics.ThermalCritical:
			checked++
			critical++
		}
	}
	if checked == 0 {
		return "Térmico: não avaliado"
	}
	return fmt.Sprintf("Térmico: %d crít | %d alertas | %d avaliados", critical, warning, checked)
}
