// crias-tui-next is an opt-in, presentation-only prototype. It does not
// invoke managers, sudo, systemctl, package tools or configuration writes.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"golang.org/x/term"
)

type model struct {
	state app.State
	color bool
}

func (m model) Init() tea.Cmd { return nil }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch v := msg.(type) {
	case tea.WindowSizeMsg:
		m.state = m.state.Resize(v.Width, v.Height)
	case tea.KeyPressMsg:
		next, quit := m.state.Key(v.String())
		m.state = next
		if quit {
			return m, tea.Quit
		}
	}
	return m, nil
}

// The C01 layout deliberately uses ASCII, bounded rows and no timers. C02
// will own the responsive design system; no synthetic host metrics here.
func (m model) View() tea.View {
	s := m.state
	lines := []string{"CRIAS HUB | C01", "Experimental - somente leitura", "", "Area: " + s.Section()}
	if s.Detail {
		lines = append(lines, "Nenhuma operacao administrativa disponivel.")
	}
	lines = append(lines, "", "1-6 / Left Right / Tab: areas", "Enter: detalhes | Esc: voltar | Q: sair")
	if s.Width < 40 || s.Height < 10 {
		lines = []string{"CRIAS HUB", s.Section(), "Q: sair"}
	}
	width := max(0, s.Width-1)
	height := min(len(lines), max(0, s.Height))
	lines = lines[:height]
	for i, line := range lines {
		if len(line) > width {
			lines[i] = line[:width]
		}
	}
	if m.color && len(lines) > 0 {
		lines[0] = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("2")).Render(lines[0])
	}
	v := tea.NewView(strings.Join(lines, "\n"))
	v.AltScreen = true
	return v
}

const help = "crias-tui-next: prototipo C01 somente leitura\nUso: crias-tui-next [--help | --version]\nSem TTY: use crias-tui --doctor (legado)."

func run(args []string, stdin, stdout *os.File, stderr io.Writer) int {
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			fmt.Fprintln(stdout, help)
			return 0
		case "--version":
			fmt.Fprintln(stdout, "crias-tui-next C01 experimental")
			return 0
		}
	}
	if len(args) != 0 {
		fmt.Fprintln(stderr, help)
		return 2
	}
	if !term.IsTerminal(int(stdin.Fd())) || !term.IsTerminal(int(stdout.Fd())) ||
		os.Getenv("TERM") == "" || os.Getenv("TERM") == "dumb" {
		fmt.Fprintln(stderr, "Terminal interativo necessario; use crias-tui --doctor.")
		return 2
	}
	if os.Geteuid() == 0 {
		fmt.Fprintln(stderr, "Prototipo C01: execute sem root.")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	_, noColor := os.LookupEnv("NO_COLOR")
	p := tea.NewProgram(model{state: app.New(), color: !noColor}, tea.WithContext(ctx), tea.WithInput(stdin), tea.WithOutput(stdout))
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(stderr, "C01:", err)
		return 1
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
