// Package app contains the deterministic state of the read-only C01 prototype.
package app

var sections = [...]string{"Visao geral", "Servidores", "Hardware", "Backups", "Sistema", "Configuracoes"}

type State struct {
	Tab    int
	Detail bool
	Width  int
	Height int
}

func New() State {
	return State{Width: 80, Height: 24}
}

func (s State) Section() string {
	return sections[s.Tab]
}

func (s State) Resize(width, height int) State {
	s.Width = max(0, width)
	s.Height = max(0, height)
	return s
}

// Key returns the next state and whether to quit. No effects or privileged
// calls are available to this state machine.
func (s State) Key(key string) (State, bool) {
	switch key {
	case "q", "ctrl+c":
		return s, true
	case "esc":
		if s.Detail {
			s.Detail = false
			return s, false
		}
		return s, true
	case "left", "shift+tab":
		s.Tab = (s.Tab + len(sections) - 1) % len(sections)
		s.Detail = false
	case "right", "tab":
		s.Tab = (s.Tab + 1) % len(sections)
		s.Detail = false
	case "1", "2", "3", "4", "5", "6":
		s.Tab = int(key[0] - '1')
		s.Detail = false
	case "enter":
		s.Detail = true
	}
	return s, false
}
