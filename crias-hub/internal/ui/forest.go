// Package ui renders the Crias Forest presentation without side effects.
package ui

import (
	"fmt"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
)

const (
	forestBackground = "#111713"
	forestSurface    = "#202E24"
	forestAccent     = "#94D5A5"
	forestMuted      = "#91A89A"
	forestText       = "#DCE9DF"
)

type Options struct {
	Color     bool
	ASCII     bool
	Palette16 bool
	Telemetry *metrics.Snapshot
}

type role uint8

const (
	normal role = iota
	heading
	surface
	muted
)

type line struct {
	text string
	role role
}

var transliterate = strings.NewReplacer(
	"á", "a", "à", "a", "â", "a", "ã", "a", "é", "e", "ê", "e",
	"í", "i", "ó", "o", "ô", "o", "õ", "o", "ú", "u", "ç", "c",
	"Á", "A", "À", "A", "Â", "A", "Ã", "A", "É", "E", "Ê", "E",
	"Í", "I", "Ó", "O", "Ô", "O", "Õ", "O", "Ú", "U", "Ç", "C",
	"°", " graus ", "—", "-", "·", "|", "←", "<", "→", ">", "↑", "^", "↓", "v",
)

// fit is used for built-in labels and bounded validated search input. It measures
// display columns before adding ANSI styling, never slices UTF-8 by bytes.
func fit(text string, width int) string {
	if width <= 0 {
		return ""
	}
	if lipgloss.Width(text) <= width {
		return text
	}
	var b strings.Builder
	for _, r := range text {
		// Current labels and accepted query contain Portuguese letters and ASCII.
		// Dynamic/untrusted strings need grapheme-aware handling in C03+.
		if lipgloss.Width(b.String()+string(r)) > width {
			break
		}
		b.WriteRune(r)
	}
	return b.String()
}

func pad(text string, width int) string {
	text = fit(text, width)
	return text + strings.Repeat(" ", max(0, width-lipgloss.Width(text)))
}

func styled(l line, width int, opt Options) string {
	if opt.ASCII {
		l.text = transliterate.Replace(l.text)
	}
	text := fit(l.text, width)
	if !opt.Color || text == "" {
		return text
	}
	if opt.Palette16 {
		// ANSI colors follow the user's terminal palette. Avoid explicit
		// backgrounds in limited-color mode; labels retain textual focus.
		style := lipgloss.NewStyle()
		if l.role == heading || l.role == surface {
			style = style.Bold(true).Foreground(lipgloss.Color("2"))
		}
		return style.Render(text)
	}
	style := lipgloss.NewStyle().Foreground(lipgloss.Color(forestText)).Background(lipgloss.Color(forestBackground))
	switch l.role {
	case heading:
		style = style.Foreground(lipgloss.Color(forestAccent)).Bold(true)
	case surface:
		style = style.Foreground(lipgloss.Color(forestAccent)).Background(lipgloss.Color(forestSurface))
	case muted:
		style = style.Foreground(lipgloss.Color(forestMuted))
	}
	return style.Render(text)
}

func tabs(active, width int) []line {
	var out []line
	row := ""
	for i, name := range app.Sections() {
		label := fmt.Sprintf("%d %s", i+1, name)
		if i == active {
			label = "[" + label + "]"
		}
		if row != "" && lipgloss.Width(row+"  "+label) > width {
			out = append(out, line{row, surface})
			row = ""
		}
		if row != "" {
			row += "  "
		}
		row += label
	}
	if row != "" {
		out = append(out, line{row, surface})
	}
	return out
}

var summaries = [...]string{
	"Painel inicial e estado do host",
	"Minecraft e Terraria",
	"CPU, memória, temperatura e energia",
	"Histórico, retenção e restauração",
	"Serviços, rede, armazenamento e Doctor",
	"Interface, monitoramento e preferências",
}

func focusLabel(f app.Focus) string {
	switch f {
	case app.FocusContent:
		return "Conteúdo"
	case app.FocusContext:
		return "Contexto"
	default:
		return "Abas"
	}
}

// Overlays replace the body on small terminals instead of drawing outside
// the viewport. Keep the selected result in view as height shrinks.
func overlay(s app.State, height int) ([]line, string) {
	if s.Overlay == app.OverlayHelp {
		return []line{
			{"Ajuda · navegação", heading},
			{"1-6 / setas / Tab: áreas", normal},
			{"F6: foco | F2: lateral", normal},
			{"/: buscar | Enter: detalhes", normal},
			{"Esc: voltar | Q: sair", normal},
			{"Ctrl+C: sair com restauração", muted},
			{"Somente navegação; sem ações administrativas.", muted},
		}, "Esc: fechar ajuda"
	}
	rows := []line{{"Busca · somente navegação", heading}, {"Consulta: " + s.Query, normal}}
	results := s.SearchResults()
	if len(results) == 0 {
		rows = append(rows, line{"Nenhum resultado", muted})
	} else {
		available := max(1, height-4)
		start := max(0, s.Selection-available+1)
		for i := start; i < min(len(results), start+available); i++ {
			tab := results[i]
			label := fmt.Sprintf("%d %s", tab+1, app.Sections()[tab])
			r := normal
			if i == s.Selection {
				label = "> " + label
				r = heading
			} else {
				label = "  " + label
			}
			rows = append(rows, line{label, r})
		}
	}
	return rows, "↑ ↓ / Tab | Enter | Esc: fechar"
}

// Render keeps a one-column safety margin against terminal auto-wrap. A
// compact footer stays visible when height permits; no synthetic host data.
func Render(s app.State, opt Options) string {
	width, height := max(0, s.Width-1), max(0, s.Height)
	if width == 0 || height == 0 {
		return ""
	}
	version := "C02"
	if opt.Telemetry != nil {
		version = "C03"
	}
	lines := []line{{"CRIAS HUB | " + version, heading}}
	compact := width < 59 || height < 20
	wide := s.ContextVisible()
	footer := "1-6 / ← → / Tab | F6: foco | F2: lateral | /: busca | ?: ajuda | Q: sair"
	if s.Detail {
		footer = "Esc: fechar detalhes | F6: foco | /: busca | ?: ajuda | Q: sair"
	}
	if s.Overlay != app.OverlayNone {
		if s.Overlay == app.OverlaySearch && !s.SearchUsable() {
			lines = append(lines, line{"Busca: amplie o terminal.", muted})
			return finish(lines, "Esc: voltar", width, height, opt)
		}
		rows, hint := overlay(s, height)
		lines = append(lines, rows...)
		return finish(lines, hint, width, height, opt)
	}
	if compact {
		lines = append(lines, line{"Área: " + s.Section(), normal})
		if height >= 5 {
			lines = append(lines, line{"Foco: " + focusLabel(s.Focus), muted})
		}
		if opt.Telemetry != nil && height >= 6 {
			lines = append(lines, line{hostSummary(*opt.Telemetry), normal})
		}
		if s.Detail {
			lines = append(lines, line{"Nenhuma operação administrativa disponível.", muted})
		}
	} else {
		lines = append(lines, line{"Experimental · somente leitura | Foco: " + focusLabel(s.Focus), muted})
		if opt.Telemetry == nil {
			lines = append(lines, line{"Host e métricas: indisponíveis (C03)", muted})
		} else {
			lines = append(lines, line{hostSummary(*opt.Telemetry), normal})
		}
		lines = append(lines, tabs(s.Tab, width)...)
		lines = append(lines, line{strings.Repeat("-", min(width, 100)), muted})
		lines = append(lines, line{"Área: " + s.Section(), heading})
		if opt.Telemetry != nil && (s.Tab == 0 || s.Tab == 2) {
			lines = append(lines, telemetryRows(*opt.Telemetry, s.Tab == 2)...)
			if wide {
				lines = append(lines, line{"Contexto | Somente leitura", muted})
			}
		} else if wide {
			left := width - 29
			lines = append(lines,
				line{pad(summaries[s.Tab], left) + " | Contexto", normal},
				line{pad("Recursos ainda não conectados.", left) + " | Somente leitura", muted},
				line{pad("Nenhum dado do host é simulado.", left) + " | C03: métricas", muted},
				line{pad("", left) + " | C04: paridade", muted})
		} else {
			lines = append(lines,
				line{summaries[s.Tab], normal},
				line{"Recursos ainda não conectados.", muted},
				line{"Nenhum dado do host é simulado.", muted})
		}
		if s.Detail {
			lines = append(lines, line{"Nenhuma operação administrativa disponível.", muted})
		}
	}
	if compact || lipgloss.Width(footer) > width {
		footer = "1-6 / Tab | / | ? | Q: sair"
		if width < 27 {
			footer = "/ ? Q: sair"
		}
	}
	return finish(lines, footer, width, height, opt)
}

func finish(lines []line, footer string, width, height int, opt Options) string {
	if height > 1 {
		lines = lines[:min(len(lines), height-1)]
		lines = append(lines, line{footer, muted})
	} else {
		lines = lines[:1]
	}
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, styled(l, width, opt))
	}
	return strings.Join(out, "\n")
}
