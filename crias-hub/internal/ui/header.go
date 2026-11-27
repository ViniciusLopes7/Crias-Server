package ui

import (
	"fmt"
	"strings"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

// Only CPU package readings with known driver semantics qualify for the
// header. Never substitute GPU, NVMe or an ambiguous ACPI zone.
func cpuTemperature(r metrics.Reading[metrics.Sensors]) string {
	if r.State != metrics.Available {
		return "Temp CPU: " + availability(r.State)
	}
	for _, candidate := range []struct {
		driver string
		label  string
		title  string
		prefix bool
	}{
		{"k10temp", "Tdie", "CPU Tdie máx", false},
		{"coretemp", "Package id ", "CPU pacote máx", true},
		{"k10temp", "Tctl", "CPU Tctl máx", false},
	} {
		var highest metrics.Sample
		for _, v := range r.Data.Values {
			match := v.Label == candidate.label
			if candidate.prefix {
				match = strings.HasPrefix(v.Label, candidate.label)
			}
			if v.Driver != candidate.driver || !match || v.Value.Unit != metrics.Celsius || !v.Value.Valid() {
				continue
			}
			if !highest.Valid() || v.Value.Value > highest.Value {
				highest = v.Value
			}
		}
		if highest.Valid() {
			return fmt.Sprintf("%s: %.1f°C", candidate.title, highest.Value)
		}
	}
	return "Temp CPU: indisponível"
}

// Powercap domains may overlap. Only a single named package can be
// summarized, without implying whole-host power or summing domains.
func packagePower(r metrics.Reading[metrics.PowerDomains]) string {
	const label = "Pot. pacote CPU: "
	if r.State != metrics.Available {
		return label + availability(r.State)
	}
	var packages []metrics.PowerDomain
	for _, d := range r.Data.Values {
		if d.NameState == metrics.Available && strings.HasPrefix(d.Name, "package-") {
			packages = append(packages, d)
		}
	}
	if len(packages) > 1 {
		return label + "múltiplos (ver Hardware)"
	}
	if len(packages) == 0 {
		return label + "indisponível"
	}
	sample, average := packages[0].SummaryEvidence()
	if sample.State == metrics.Available || sample.State == metrics.Estimated {
		source, estimate := "instant.", ""
		if average {
			source = "média"
		}
		if sample.State == metrics.Estimated {
			estimate = "~"
		}
		return fmt.Sprintf("%s%s%.1f W (%s)", label, estimate, sample.Value, source)
	}
	return label + availability(sample.State)
}

func batteryHeader(r metrics.Reading[metrics.PowerSupplies]) string {
	const label = "Bat: "
	if r.State != metrics.Available {
		return label + availability(r.State)
	}
	var batteries []metrics.Battery
	for _, b := range r.Data.Batteries {
		if b.Present.Valid() && b.Present.Unit == metrics.Boolean && b.Present.Value == 0 {
			continue
		}
		batteries = append(batteries, b)
	}
	switch len(batteries) {
	case 0:
		return label + "ausente"
	case 1:
		b := batteries[0]
		if b.Capacity.Valid() && b.Capacity.Unit == metrics.Percent && (b.Capacity.Value < 0 || b.Capacity.Value > 100) {
			return label + "inválido"
		}
		return label + percent(b.Capacity)
	default:
		return label + "múltiplas"
	}
}

func hardwareHeader(s metrics.Snapshot) []line {
	h := s.Hardware
	return []line{
		{cpuTemperature(h.Sensors) + " | " + batteryHeader(h.Supplies), normal},
		{packagePower(h.Domains), normal},
	}
}
