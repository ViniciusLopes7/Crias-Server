// crias-tui-next is an opt-in, presentation-only prototype. It does not
// invoke managers, sudo, systemctl, package tools or configuration writes.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	tea "charm.land/bubbletea/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/ui"
	"golang.org/x/term"
)

type model struct {
	state app.State
	color bool
	ascii bool
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

// View renders state only; no host reads or effects in the render loop.
func (m model) View() tea.View {
	v := tea.NewView(ui.Render(m.state, ui.Options{Color: m.color, ASCII: m.ascii}))
	v.AltScreen = true
	return v
}

const help = "crias-tui-next: prototipo C02 somente leitura\nUso: crias-tui-next [--help | --version]\nSem TTY: use crias-tui --doctor (legado)."

func run(args []string, stdin, stdout *os.File, stderr io.Writer) int {
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			fmt.Fprintln(stdout, help)
			return 0
		case "--version":
			fmt.Fprintln(stdout, "crias-tui-next C02 experimental")
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
		fmt.Fprintln(stderr, "Prototipo C02: execute sem root.")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	_, noColor := os.LookupEnv("NO_COLOR")
	ascii := os.Getenv("CRIAS_HUB_ASCII") == "1"
	p := tea.NewProgram(model{state: app.New(), color: !noColor, ascii: ascii}, tea.WithContext(ctx), tea.WithInput(stdin), tea.WithOutput(stdout))
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(stderr, "C02:", err)
		return 1
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
