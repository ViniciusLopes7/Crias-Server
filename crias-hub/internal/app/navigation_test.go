package app

import (
	"strings"
	"testing"
)

func press(s State, keys ...string) State {
	for _, key := range keys {
		s, _ = s.Key(key)
	}
	return s
}

func TestSearchNavigationOnly(t *testing.T) {
	s := press(New(), "2", "enter", "/", "m", "e", "m", "ó", "r", "i", "a")
	if s.Overlay != OverlaySearch || s.Tab != 1 || !s.Detail {
		t.Fatalf("search changed underlying state: %+v", s)
	}
	if got := s.SearchResults(); len(got) != 1 || got[0] != 2 {
		t.Fatalf("accent-insensitive query: %v", got)
	}
	s = press(s, "enter")
	if s.Overlay != OverlayNone || s.Tab != 2 || s.Detail || s.Query != "" {
		t.Fatalf("search did not navigate safely: %+v", s)
	}
	s = press(s, "/", "q", "6")
	if s.Query != "q6" || s.Tab != 2 || len(s.SearchResults()) != 0 {
		t.Fatalf("global shortcuts leaked into query: %+v", s)
	}
	s = press(s, "enter")
	if s.Overlay != OverlaySearch || s.Tab != 2 {
		t.Fatal("empty result executed navigation")
	}
	s = press(s, "esc")
	if s.Overlay != OverlayNone || s.Tab != 2 {
		t.Fatal("escape lost context")
	}
}

func TestSearchBoundsAndSelection(t *testing.T) {
	s := press(New(), "/", "up")
	if s.Selection != 5 {
		t.Fatalf("wrap: %d", s.Selection)
	}
	s = press(s, "down", "tab", "shift+tab")
	if s.Selection != 0 {
		t.Fatal("selection wrap")
	}
	s = press(s, "á", "backspace", "\x1b[31m", "ctrl+v", "multiple")
	if s.Query != "" {
		t.Fatalf("accepted unsupported input: %q", s.Query)
	}
	for range MaxQuery + 5 {
		s = press(s, "a")
	}
	if s.Query != strings.Repeat("a", MaxQuery) {
		t.Fatal("query bound not enforced")
	}
	if _, quit := s.Key("q"); quit {
		t.Fatal("q quit while searching")
	}
	if _, quit := s.Key("ctrl+c"); !quit {
		t.Fatal("Ctrl+C cannot restore terminal")
	}
}

func TestFocusAndResponsiveContext(t *testing.T) {
	s := press(New().Resize(120, 40), "f6", "f6")
	if s.Focus != FocusContext {
		t.Fatal("context focus not reachable")
	}
	s = press(s, "enter")
	if s.Detail {
		t.Fatal("passive context opened detail")
	}
	s = press(s, "f2")
	if s.ContextVisible() || s.Focus != FocusContent {
		t.Fatal("hiding context stranded focus")
	}
	s = press(s, "f2", "f6")
	if !s.ContextVisible() || s.Focus != FocusContext {
		t.Fatal("context not restored")
	}
	s = s.Resize(80, 24)
	if s.ContextVisible() || s.Focus != FocusContent {
		t.Fatal("resize stranded focus")
	}
	s = press(s, "?", "6", "q")
	if s.Overlay != OverlayHelp || s.Tab != 0 {
		t.Fatal("help leaked shortcuts")
	}
	s = press(s, "esc")
	if s.Focus != FocusContent || s.Overlay != OverlayNone {
		t.Fatal("help lost previous focus")
	}
}
