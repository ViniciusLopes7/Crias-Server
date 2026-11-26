package ui

import (
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

type MonitorView struct {
	Profile      metrics.Profile
	Window       time.Duration
	CPU          metrics.Stats
	RAM          metrics.Stats
	HardwarePage int
}

func monitorSettings(p metrics.Profile) []line {
	name := "Balanceado"
	switch p {
	case metrics.Economy:
		name = "Econômico"
	case metrics.Detailed:
		name = "Detalhado"
	}
	return []line{
		{"Monitoramento: " + name, heading},
		{"P: alternar perfil de coleta", normal},
		{fmt.Sprintf("CPU/RAM: %s | Sensores: %s", p.Interval(time.Second), p.Interval(2*time.Second)), normal},
		{fmt.Sprintf("Bateria: %s | Espaço: %s", p.Interval(10*time.Second), p.Interval(30*time.Second)), normal},
		{"Válido nesta sessão; sem alterar energia ou hardware.", muted},
	}
}

func historyRows(m MonitorView) []line {
	window := m.Window
	if window == 0 {
		window = time.Minute
	}
	rows := []line{{fmt.Sprintf("Histórico %d min | H: janela", int(window.Minutes())), heading}}
	for _, v := range []struct {
		name string
		stat metrics.Stats
	}{{"CPU", m.CPU}, {"RAM", m.RAM}} {
		s := v.stat
		if s.Count == 0 {
			rows = append(rows, line{v.name + ": sem amostras válidas", muted})
			continue
		}
		rows = append(rows, line{fmt.Sprintf("%s mín/média/máx: %.1f/%.1f/%.1f%%", v.name, s.Min, s.Mean, s.Max), normal})
		gap := ""
		if s.Gap {
			gap = " | lacunas"
		}
		rows = append(rows, line{fmt.Sprintf("%d válidas | %d ausentes | cobertura %.0fs%s", s.Count, s.Missing, s.Last.Sub(s.First).Seconds(), gap), muted})
	}
	return rows
}

// Kernel labels already have read-side restrictions. Apply a second
// printable ASCII boundary here so fixture or future data cannot inject
// terminal escapes, newlines or control sequences into the view.
func deviceLabel(s string) string {
	if len(s) > 256 {
		s = s[:256] + "..."
	}
	return strings.Map(func(r rune) rune {
		if r < 32 || r > 126 {
			return '?'
		}
		return r
	}, s)
}

func measurement(s metrics.Sample) string {
	if s.State != metrics.Available && s.State != metrics.Estimated {
		return availability(s.State)
	}
	if math.IsNaN(s.Value) || math.IsInf(s.Value, 0) {
		return "inválido"
	}
	unit := string(s.Unit)
	switch s.Unit {
	case metrics.Percent, metrics.MHz, metrics.Celsius, metrics.RPM, metrics.Watts, metrics.WattHours, metrics.AmpHours, metrics.Volts, metrics.Amps, metrics.Joules, metrics.BytesRate:
	default:
		return "indisponível"
	}
	prefix := ""
	if s.State == metrics.Estimated {
		prefix = "~"
	}
	return fmt.Sprintf("%s%.1f %s", prefix, s.Value, unit)
}

func hardwareRows(s metrics.Snapshot) []line {
	h := s.Hardware
	rows := capabilityRows(h)
	group := func(label string, state metrics.Availability, count int) bool {
		rows = append(rows, inventory(label, state, count))
		return state == metrics.Available
	}
	add := func(text string) {
		for _, part := range wrapHardware(text) {
			rows = append(rows, line{part, normal})
		}
	}
	if group("Políticas CPU", h.Frequencies.State, len(h.Frequencies.Data.Policies)) {
		for _, p := range h.Frequencies.Data.Policies {
			id := deviceLabel(p.ID)
			governor := availability(p.GovernorState)
			if p.GovernorState == metrics.Available {
				governor = deviceLabel(p.Governor)
			}
			add(id + " | hardware " + measurement(p.Observed) + " | driver " + measurement(p.Requested))
			add(id + " | mín " + measurement(p.ConfiguredMin) + " | máx " + measurement(p.ConfiguredMax) + " | " + governor)
		}
	}
	for _, g := range []struct {
		name string
		data metrics.Reading[metrics.Sensors]
	}{{"Sensores hwmon", h.Sensors}, {"Zonas térmicas", h.Thermal}} {
		if group(g.name, g.data.State, len(g.data.Data.Values)) {
			for _, v := range g.data.Data.Values {
				add(deviceLabel(v.ID+" "+v.Driver+" "+v.Label) + ": " + measurement(v.Value))
				if v.Alert != "" && v.Alert != metrics.ThermalUnknown {
					add("Térmico: " + thermalLabel(v.Alert) + " | máx " + measurement(v.Limits.Max) + " | crít " + measurement(v.Limits.Critical))
				}
			}
		}
	}
	if group("Domínios de energia", h.Domains.State, len(h.Domains.Data.Values)) {
		for _, d := range h.Domains.Data.Values {
			id := deviceLabel(d.ID + " " + d.Name)
			add(id + " | instantânea " + measurement(d.Instant))
			add(id + " | média " + measurement(d.Average) + " | contador " + measurement(d.Energy))
		}
	}
	add("Potência total do host: indisponível")
	if group("Baterias e fontes", h.Supplies.State, len(h.Supplies.Data.Batteries)+len(h.Supplies.Data.External)) {
		for _, b := range h.Supplies.Data.Batteries {
			id := deviceLabel(b.ID)
			status := availability(b.StatusState)
			if b.StatusState == metrics.Available {
				status = deviceLabel(b.Status)
			}
			if b.Present.Valid() && b.Present.Value == 0 {
				add(id + ": ausente")
				continue
			}
			add(id + " | " + status + " | capacidade " + measurement(b.Capacity) + " | saúde " + measurement(b.Health))
			add(id + " | potência " + measurement(b.Power) + " | energia " + measurement(b.EnergyNow) + " | carga " + measurement(b.ChargeNow))
			add(id + " | limites " + measurement(b.StartLimit) + " / " + measurement(b.EndLimit) + " (leitura)")
		}
		for _, v := range h.Supplies.Data.External {
			state := availability(v.Online.State)
			if v.Online.Valid() {
				state = "desconectada"
				if v.Online.Value == 1 {
					state = "conectada"
				}
			}
			add(deviceLabel(v.ID+" "+v.Kind) + ": " + state)
		}
	}
	for _, g := range []struct {
		name       string
		directions string
		data       metrics.Reading[metrics.Transfers]
	}{{"Rede", "RX/TX", h.Network}, {"Disco", "leitura/escrita", h.Disk}} {
		if group(g.name, g.data.State, len(g.data.Data.Values)) {
			for _, v := range g.data.Data.Values {
				add(deviceLabel(v.ID) + " " + g.directions + ": " + measurement(v.ReadRate) + " / " + measurement(v.WriteRate))
			}
		}
	}
	return rows
}

// Wrap before pagination, using the ASCII fallback width so expanded
// units (degrees) also fit. Long unbroken device labels are split.
func wrapHardware(text string) []string {
	const width = 55
	var out []string
	row := ""
	columns := func(s string) int { return len(transliterate.Replace(s)) }
	for _, word := range strings.Fields(text) {
		for columns(word) > width {
			if row != "" {
				out = append(out, row)
				row = ""
			}
			runes := []rune(word)
			n := 1
			for n < len(runes) && columns(string(runes[:n+1])) <= width {
				n++
			}
			out = append(out, string(runes[:n]))
			word = string(runes[n:])
		}
		if row != "" && columns(row+" "+word) > width {
			out = append(out, row)
			row = ""
		}
		if row != "" {
			row += " "
		}
		row += word
	}
	if row != "" {
		out = append(out, row)
	}
	return out
}

// Fixed six-row pages fit even at the minimum full-size terminal,
// including the wrapped tab bar and footer. All rows remain reachable.
const hardwarePageSize = 6

func HardwarePages(s metrics.Snapshot) int {
	return max(1, (len(hardwareRows(s))+hardwarePageSize-1)/hardwarePageSize)
}

func hardwarePage(s metrics.Snapshot, page int) []line {
	rows := hardwareRows(s)
	pages := max(1, (len(rows)+hardwarePageSize-1)/hardwarePageSize)
	page = min(max(page, 0), pages-1)
	start := page * hardwarePageSize
	out := []line{{fmt.Sprintf("Hardware %d/%d | ~ estimado | somente leitura", page+1, pages), heading}}
	return append(out, rows[start:min(len(rows), start+hardwarePageSize)]...)
}
