// Package app contains the deterministic state of the read-only Hub prototype.
package app

import (
	"strings"
	"unicode/utf8"
)

var sections = [...]string{"Visão geral", "Servidores", "Hardware", "Backups", "Sistema", "Configurações"}
var keywords = [...]string{"painel host estado", "minecraft terraria jogos console", "cpu memória ram temperatura energia bateria", "backup histórico retenção restauração", "serviços rede armazenamento doctor ssh tailscale", "interface monitoramento preferências"}

func Sections() [6]string { return sections }

type Focus uint8

const (
	FocusTabs Focus = iota
	FocusContent
	FocusContext
)

type Overlay uint8

const (
	OverlayNone Overlay = iota
	OverlaySearch
	OverlayHelp
)

const MaxQuery = 48

type State struct {
	Tab           int
	Detail        bool
	Width         int
	Height        int
	Focus         Focus
	ContextHidden bool
	Overlay       Overlay
	Query         string
	Selection     int
}

func New() State               { return State{Width: 80, Height: 24} }
func (s State) Section() string { return sections[s.Tab] }

func (s State) ContextVisible() bool {
	return !s.ContextHidden && s.Width >= 100 && s.Height >= 30
}

func (s State) Resize(width, height int) State {
	s.Width = max(0, width)
	s.Height = max(0, height)
	if !s.ContextVisible() && s.Focus == FocusContext {
		s.Focus = FocusContent
	}
	return s
}

var accents = strings.NewReplacer("á", "a", "à", "a", "â", "a", "ã", "a", "é", "e", "ê", "e", "í", "i", "ó", "o", "ô", "o", "õ", "o", "ú", "u", "ç", "c")

func fold(text string) string {
	return accents.Replace(strings.ToLower(text))
}

// SearchResults contains only canonical tab indices, never commands.
func (s State) SearchResults() []int {
	terms := strings.Fields(fold(s.Query))
	results := make([]int, 0, len(sections))
	for i, name := range sections {
		text := fold(name + " " + keywords[i])
		match := true
		for _, term := range terms {
			if !strings.Contains(text, term) {
				match = false
				break
			}
		}
		if match {
			results = append(results, i)
		}
	}
	return results
}

func (s State) selectTab(tab int) State {
	s.Tab, s.Detail, s.Focus = tab, false, FocusTabs
	return s
}

func (s State) closeOverlay() State {
	s.Overlay, s.Query, s.Selection = OverlayNone, "", 0
	return s
}

func (s State) searchKey(key string) State {
	switch key {
	case "esc":
		return s.closeOverlay()
	case "enter":
		results := s.SearchResults()
		if s.Selection >= 0 && s.Selection < len(results) {
			return s.closeOverlay().selectTab(results[s.Selection])
		}
	case "up", "shift+tab", "down", "tab":
		count := len(s.SearchResults())
		if count > 0 {
			delta := 1
			if key == "up" || key == "shift+tab" {
				delta = -1
			}
			s.Selection = (s.Selection + delta + count) % count
		}
	case "backspace":
		if s.Query != "" {
			_, size := utf8.DecodeLastRuneInString(s.Query)
			s.Query = s.Query[:len(s.Query)-size]
			s.Selection = 0
		}
	default:
		if key == "space" {
			key = " "
		}
		r, size := utf8.DecodeRuneInString(key)
		// Allow only printable ASCII and the Portuguese alphabet used by
		// the search index. Reject control/escape sequences and paste bursts.
		if size == len(key) && size > 0 && utf8.RuneCountInString(s.Query) < MaxQuery &&
			((r >= ' ' && r <= '~') || strings.ContainsRune("áàâãéêíóôõúçÁÀÂÃÉÊÍÓÔÕÚÇ", r)) {
			s.Query += key
			s.Selection = 0
		}
	}
	return s
}

func (s State) cycleFocus() State {
	switch s.Focus {
	case FocusTabs:
		s.Focus = FocusContent
	case FocusContent:
		if s.ContextVisible() {
			s.Focus = FocusContext
		} else {
			s.Focus = FocusTabs
		}
	default:
		s.Focus = FocusTabs
	}
	return s
}

// Key returns the next state and whether to quit. Global navigation is
// suspended inside overlays; Ctrl+C always requests terminal restoration.
func (s State) Key(key string) (State, bool) {
	if key == "ctrl+c" {
		return s, true
	}
	switch s.Overlay {
	case OverlaySearch:
		return s.searchKey(key), false
	case OverlayHelp:
		if key == "esc" || key == "?" {
			return s.closeOverlay(), false
		}
		return s, false
	}
	switch key {
	case "q", "Q":
		return s, true
	case "esc":
		if s.Detail {
			s.Detail = false
			s.Focus = FocusTabs
			return s, false
		}
		if s.Focus != FocusTabs {
			s.Focus = FocusTabs
			return s, false
		}
		return s, true
	case "/":
		s.Overlay, s.Query, s.Selection = OverlaySearch, "", 0
	case "?":
		s.Overlay = OverlayHelp
	case "f6":
		s = s.cycleFocus()
	case "f2":
		s.ContextHidden = !s.ContextHidden
		if !s.ContextVisible() && s.Focus == FocusContext {
			s.Focus = FocusContent
		}
	case "left", "shift+tab":
		s = s.selectTab((s.Tab + len(sections) - 1) % len(sections))
	case "right", "tab":
		s = s.selectTab((s.Tab + 1) % len(sections))
	case "1", "2", "3", "4", "5", "6":
		s = s.selectTab(int(key[0] - '1'))
	case "enter":
		if s.Focus != FocusContext {
			s.Detail = true
			s.Focus = FocusContent
		}
	}
	return s, false
}
