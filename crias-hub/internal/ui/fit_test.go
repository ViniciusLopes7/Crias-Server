package ui

import (
	"strings"
	"testing"

	"charm.land/lipgloss/v2"
)

func fitReference(text string, width int) string {
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

func TestFitASCIIEquivalence(t *testing.T) {
	var ascii strings.Builder
	for i := 32; i <= 126; i++ {
		ascii.WriteByte(byte(i))
	}
	inputs := []string{
		"", "CRIAS HUB | C03", ascii.String(), strings.Repeat("x", 512),
		"Memória e potência", "界🙂", "e\u0301", "\x1b[31mred\x1b[0m",
		"line\nnext", "a\tb", "\x7f", string([]byte{255, 0, 65}),
	}
	for _, text := range inputs {
		for _, width := range []int{-1, 0, 1, 2, 5, 20, 59, 119, 512, 1024} {
			if got, want := fit(text, width), fitReference(text, width); got != want {
				t.Fatalf("fit(%q, %d) = %q, want %q", text, width, got, want)
			}
		}
	}
}

func BenchmarkFitWidth(b *testing.B) {
	for _, tc := range []struct {
		name  string
		text  string
		width int
	}{
		{"ascii-fit", "CPU host: 23.4% | RAM host: 1024 MiB", 119},
		{"ascii-truncate", strings.Repeat("Hardware details | ", 12), 59},
		{"unicode", "Memória e potência | 温度", 119},
	} {
		b.Run(tc.name+"/reference", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = fitReference(tc.text, tc.width)
			}
		})
		b.Run(tc.name+"/current", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = fit(tc.text, tc.width)
			}
		})
	}
}
