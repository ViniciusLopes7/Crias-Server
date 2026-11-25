package ui

import (
	"strings"
	"testing"
	"unicode/utf8"

	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
)

func TestRenderMatrix(t *testing.T) {
	for _, size := range [][2]int{{120, 40}, {100, 30}, {80, 24}, {60, 20}, {59, 19}, {20, 5}, {1, 1}, {0, 0}} {
		for tab := range app.Sections() {
			for _, detail := range []bool{false, true} {
				for _, opt := range []Options{{}, {ASCII: true}, {Color: true}, {ASCII: true, Color: true}} {
					s := app.New().Resize(size[0], size[1])
					s.Tab, s.Detail = tab, detail
					got := Render(s, opt)
					if !utf8.ValidString(got) || lipgloss.Width(got) > max(0, size[0]-1) ||
						(size[1] > 0 && lipgloss.Height(got) > size[1]) {
						t.Fatalf("overflow/invalid UTF-8 at %v tab %d detail %v opt %+v", size, tab, detail, opt)
					}
					if !opt.Color && strings.Contains(got, "\x1b") {
						t.Fatal("escape codes in no-color mode")
					}
					if opt.ASCII && !opt.Color {
						for _, r := range got {
							if r > 127 {
								t.Fatalf("non-ASCII rune %q", r)
							}
						}
					}
				}
			}
		}
	}
}

func TestActiveTabAndContext(t *testing.T) {
	s := app.New().Resize(120, 40)
	s.Tab = 2
	s.Detail = true
	got := Render(s, Options{})
	for _, want := range []string{"[3 Hardware]", "Área: Hardware", "Contexto", "Nenhuma operação administrativa disponível.", "Q: sair"} {
		if !strings.Contains(got, want) {
			t.Fatalf("missing %q", want)
		}
	}
	compact := Render(s.Resize(20, 5), Options{ASCII: true})
	if strings.Contains(compact, "Contexto") || !strings.Contains(compact, "Area: Hardware") {
		t.Fatalf("compact lost context: %q", compact)
	}
}

func TestNoFabricatedMetrics(t *testing.T) {
	got := Render(app.New().Resize(100, 30), Options{})
	if !strings.Contains(got, "indisponíveis (C03)") || !strings.Contains(got, "Nenhum dado do host é simulado.") {
		t.Fatal("missing explicit unavailable state")
	}
}

func BenchmarkRender(b *testing.B) {
	s := app.New().Resize(120, 40)
	for i := 0; i < b.N; i++ {
		_ = Render(s, Options{Color: true})
	}
}
