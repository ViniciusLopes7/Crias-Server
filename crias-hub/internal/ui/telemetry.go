package ui

import (
	"fmt"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

func availability(s metrics.Availability) string {
	switch s {
	case metrics.Waiting:
		return "aguardando"
	case metrics.Permission:
		return "sem permissão"
	case metrics.Invalid:
		return "inválido"
	case metrics.Stale:
		return "obsoleto"
	case metrics.Estimated:
		return "estimado"
	default:
		return "indisponível"
	}
}

func percent(s metrics.Sample) string {
	if !s.Valid() || s.Unit != metrics.Percent {
		return availability(s.State)
	}
	return fmt.Sprintf("%.1f%%", s.Value)
}

func memoryText(s metrics.Sample) string {
	if !s.Valid() || s.Unit != metrics.Bytes {
		return availability(s.State)
	}
	return fmt.Sprintf("%.0f MiB", s.Value/1048576)
}

func hostSummary(s metrics.Snapshot) string {
	return "CPU host: " + percent(s.CPU) + " | RAM host: " + memoryText(s.Memory.Used)
}

func inventory(label string, state metrics.Availability, n int) line {
	if state != metrics.Available {
		return line{label + ": " + availability(state), muted}
	}
	return line{fmt.Sprintf("%s: %d identificados", label, n), normal}
}

func telemetryRows(s metrics.Snapshot, hardware bool) []line {
	h := s.Hardware
	rows := []line{
		{"Memória do host · não é heap JVM", heading},
		{"RAM total: " + memoryText(s.Memory.Total) + " | Disponível: " + memoryText(s.Memory.Available), normal},
		{"RAM utilizada: " + percent(s.Memory.Usage) + " | Swap usado: " + memoryText(s.Memory.SwapUsed), normal},
	}
	if h.Space.State == metrics.Available {
		rows = append(rows, line{"Espaço / disponível: " + memoryText(h.Space.Data.Available), normal})
	} else {
		rows = append(rows, line{"Espaço /: " + availability(h.Space.State), muted})
	}
	if hardware {
		rows = append(rows,
			line{"Controles: não validados / bloqueados", muted},
			inventory("Políticas CPU", h.Frequencies.State, len(h.Frequencies.Data.Policies)),
			inventory("Sensores hwmon", h.Sensors.State, len(h.Sensors.Data.Values)),
			inventory("Zonas térmicas", h.Thermal.State, len(h.Thermal.Data.Values)),
			inventory("Domínios de energia", h.Domains.State, len(h.Domains.Data.Values)),
			inventory("Baterias e fontes", h.Supplies.State, len(h.Supplies.Data.Batteries)+len(h.Supplies.Data.External)),
			inventory("Interfaces de rede", h.Network.State, len(h.Network.Data.Values)),
			inventory("Dispositivos de bloco", h.Disk.State, len(h.Disk.Data.Values)))
	}
	return append(rows, line{"Ações administrativas: ainda não conectadas.", muted})
}
