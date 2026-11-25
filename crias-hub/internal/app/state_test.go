package app

import "testing"

func TestNavigation(t *testing.T) {
	s := New()
	for _, tc := range []struct {
		key    string
		tab    int
		detail bool
		quit   bool
	}{
		{"left", 5, false, false},
		{"right", 0, false, false},
		{"enter", 0, true, false},
		{"esc", 0, false, false},
		{"3", 2, false, false},
		{"tab", 3, false, false},
		{"shift+tab", 2, false, false},
		{"unknown", 2, false, false},
		{"enter", 2, true, false},
		{"6", 5, false, false},
		{"esc", 5, false, true},
		{"q", 5, false, true},
		{"ctrl+c", 5, false, true},
	} {
		next, quit := s.Key(tc.key)
		if next.Tab != tc.tab || next.Detail != tc.detail || quit != tc.quit {
			t.Fatalf("key %s: state=%+v quit=%v", tc.key, next, quit)
		}
		s = next
	}
}

func TestResizePreservesNavigation(t *testing.T) {
	s, _ := New().Key("4")
	s, _ = s.Key("enter")
	next := s.Resize(60, 20).Resize(-1, 0)
	if next.Tab != 3 || !next.Detail || next.Width != 0 || next.Height != 0 {
		t.Fatalf("resize lost state: %+v", next)
	}
}

func BenchmarkNavigation(b *testing.B) {
	s := New()
	for i := 0; i < b.N; i++ {
		s, _ = s.Key("right")
	}
}
