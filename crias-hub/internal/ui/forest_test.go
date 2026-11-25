package ui

import (
	"math"
	"strconv"
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
				for _, opt := range []Options{{}, {ASCII: true}, {Color: true}, {ASCII: true, Color: true}, {Color: true, Palette16: true}, {ASCII: true, Color: true, Palette16: true}} {
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

func TestOverlayBoundsAndIsolation(t *testing.T) {
	for _, size := range [][2]int{{120, 40}, {100, 30}, {80, 24}, {60, 20}, {20, 5}, {1, 1}, {0, 0}} {
		for _, keys := range [][]string{{"/"}, {"/", "up"}, {"/", "q", "6"}, {"?"}} {
			s := app.New().Resize(size[0], size[1])
			for _, key := range keys {
				s, _ = s.Key(key)
			}
			for _, opt := range []Options{{}, {ASCII: true}, {Color: true}, {ASCII: true, Color: true}, {Color: true, Palette16: true}, {ASCII: true, Color: true, Palette16: true}} {
				got := Render(s, opt)
				if !utf8.ValidString(got) || lipgloss.Width(got) > max(0, size[0]-1) ||
					(size[1] > 0 && lipgloss.Height(got) > size[1]) {
					t.Fatalf("overlay overflow at %v, keys %v, opt %+v", size, keys, opt)
				}
				if !opt.Color && strings.Contains(got, "\x1b") {
					t.Fatal("escape codes in overlay without color")
				}
			}
		}
	}
	s, _ := app.New().Key("/")
	s, _ = s.Key("up")
	got := Render(s.Resize(40, 5), Options{ASCII: true})
	if !strings.Contains(got, "> 6 Configuracoes") {
		t.Fatalf("compact search lost selected result: %q", got)
	}
}

func luminance(hex string) float64 {
	n, err := strconv.ParseUint(strings.TrimPrefix(hex, "#"), 16, 24)
	if err != nil {
		panic(err)
	}
	channel := func(shift uint) float64 {
		v := float64((n>>shift)&255) / 255
		if v <= 0.04045 {
			return v / 12.92
		}
		return math.Pow((v+0.055)/1.055, 2.4)
	}
	return 0.2126*channel(16) + 0.7152*channel(8) + 0.0722*channel(0)
}

func TestForestContrast(t *testing.T) {
	for _, pair := range [][2]string{{forestText, forestBackground}, {forestAccent, forestBackground}, {forestMuted, forestBackground}, {forestAccent, forestSurface}} {
		a, b := luminance(pair[0]), luminance(pair[1])
		ratio := (max(a, b) + 0.05) / (min(a, b) + 0.05)
		if ratio < 4.5 {
			t.Fatalf("contrast %v: %.2f", pair, ratio)
		}
	}
}

func TestContextVisibilityAndSearchGuard(t *testing.T) {
	s := app.New().Resize(120, 40)
	s, _ = s.Key("f6")
	s, _ = s.Key("f6")
	if !strings.Contains(Render(s, Options{}), "Foco: Contexto") {
		t.Fatal("context focus not identified")
	}
	s, _ = s.Key("f2")
	got := Render(s, Options{})
	if strings.Contains(got, " | Contexto") || !strings.Contains(got, "Foco: Conteúdo") {
		t.Fatal("hidden context still rendered or focus not restored")
	}
	s, _ = s.Key("/")
	s = s.Resize(40, 4)
	got = Render(s, Options{ASCII: true})
	if !strings.Contains(got, "amplie o terminal") || strings.Contains(got, "> 1") {
		t.Fatal("unusable search displayed an actionable result")
	}
}
