// crias-tui-next is an opt-in, read-only prototype. It does not
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
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/app"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/metrics"
	"github.com/ViniciusLopes7/Crias-Server/crias-hub/internal/ui"
	"golang.org/x/term"
)

type model struct {
	state    app.State
	color    bool
	ascii    bool
	basic    bool
	engine   *metrics.Engine
	ctx      context.Context
	snapshot *metrics.Snapshot
}

type metricsUpdate struct{}

func (m model) waitMetrics() tea.Cmd {
	if m.engine == nil {
		return nil
	}
	return func() tea.Msg {
		// A bounded freshness wakeup also covers the case where every
		// collector is blocked. Only one wait is scheduled at a time.
		timer := time.NewTimer(2 * time.Second)
		defer timer.Stop()
		select {
		case <-m.ctx.Done():
			return nil
		case <-m.engine.Done():
			return nil
		case <-m.engine.Changed():
		case <-timer.C:
		}
		return metricsUpdate{}
	}
}

func (m model) Init() tea.Cmd { return m.waitMetrics() }

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch v := msg.(type) {
	case metricsUpdate:
		if m.engine != nil {
			s := m.engine.Snapshot(time.Now())
			m.snapshot = &s
			return m, m.waitMetrics()
		}
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
	v := tea.NewView(ui.Render(m.state, ui.Options{Color: m.color, ASCII: m.ascii, Palette16: m.basic, Telemetry: m.snapshot}))
	v.AltScreen = true
	return v
}

// terminalOptions avoids assuming truecolor on basic terminals. NO_COLOR
// takes precedence; the terminal renderer still negotiates its capabilities.
func terminalOptions(getenv func(string) string, lookup func(string) (string, bool)) ui.Options {
	termName := strings.ToLower(getenv("TERM"))
	_, noColor := lookup("NO_COLOR")
	ascii := getenv("CRIAS_HUB_ASCII") == "1"
	limited := termName == "linux" || termName == "ansi" ||
		getenv("CRIAS_HUB_COLOR") == "16"
	monochrome := termName == "vt100" || termName == "vt220" || termName == "dumb"
	return ui.Options{Color: !noColor && !monochrome, ASCII: ascii || monochrome, Palette16: limited}
}

const help = "crias-tui-next: prototipo C03 somente leitura\nUso: crias-tui-next [--help | --version | --telemetry]\nSem TTY: use crias-tui --doctor (legado)."

func run(args []string, stdin, stdout *os.File, stderr io.Writer) int {
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			fmt.Fprintln(stdout, help)
			return 0
		case "--version":
			fmt.Fprintln(stdout, "crias-tui-next C03 experimental")
			return 0
		}
	}
	telemetry := len(args) == 1 && args[0] == "--telemetry"
	if len(args) != 0 && !telemetry {
		fmt.Fprintln(stderr, help)
		return 2
	}
	if !term.IsTerminal(int(stdin.Fd())) || !term.IsTerminal(int(stdout.Fd())) ||
		os.Getenv("TERM") == "" || os.Getenv("TERM") == "dumb" {
		fmt.Fprintln(stderr, "Terminal interativo necessario; use crias-tui --doctor.")
		return 2
	}
	if os.Geteuid() == 0 {
		fmt.Fprintln(stderr, "Prototipo C03: execute sem root.")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	options := terminalOptions(os.Getenv, os.LookupEnv)
	m := model{state: app.New(), color: options.Color, ascii: options.ASCII, basic: options.Palette16, ctx: ctx}
	if telemetry {
		m.engine = metrics.NewHostEngine(ctx, os.DirFS("/proc"), os.DirFS("/sys"), func(at time.Time) metrics.Capacity {
			return metrics.Space("/", at)
		})
		defer m.engine.Stop()
		s := m.engine.Snapshot(time.Now())
		m.snapshot = &s
	}
	p := tea.NewProgram(m, tea.WithContext(ctx), tea.WithInput(stdin), tea.WithOutput(stdout))
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(stderr, "C03:", err)
		return 1
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
