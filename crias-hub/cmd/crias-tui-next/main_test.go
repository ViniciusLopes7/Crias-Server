package main

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
)

func TestViewBounds(t *testing.T) {
	for _, size := range [][2]int{{120, 40}, {80, 24}, {60, 20}, {20, 5}, {1, 1}, {0, 0}} {
		m := model{state: app.New().Resize(size[0], size[1])}
		v := m.View()
		if !v.AltScreen {
			t.Fatal("alternate screen not requested")
		}
		if size[1] > 0 && lipgloss.Height(v.Content) > size[1] {
			t.Fatalf("height overflow at %v", size)
		}
		if lipgloss.Width(v.Content) > size[0] {
			t.Fatalf("width overflow at %v", size)
		}
	}
}

func TestResizeEvent(t *testing.T) {
	m := model{state: app.New()}
	next, cmd := m.Update(tea.WindowSizeMsg{Width: 60, Height: 20})
	if cmd != nil || !strings.Contains(next.View().Content, "CRIAS HUB") {
		t.Fatal("resize caused unexpected effect")
	}
}
