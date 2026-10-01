// Package rcon provides an RCON client for querying players and executing commands on the Minecraft server.
package rcon

import (
	"context"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorcon/rcon"
)

// Client wraps an RCON connection with a short (30s) cache to avoid reconnects.
// Safe for concurrent use.
type Client struct {
	host     string
	port     int
	password string
	enabled  bool

	// mu protects conn and lastUse from data races.
	mu       sync.Mutex
	conn     *rcon.Conn
	lastUse  time.Time
	cacheTTL time.Duration

	// Hooks for tests (can be replaced).
	dialer func(host string, port int, password string) (*rcon.Conn, error)
}

// NewClient creates an RCON client. When enabled=false, all operations return ErrRCONDisabled.
func NewClient(host string, port int, password string, enabled bool) *Client {
	c := &Client{
		host:     host,
		port:     port,
		password: password,
		enabled:  enabled,
		cacheTTL: 30 * time.Second,
		dialer:   defaultDialer,
	}
	return c
}

// ErrRCONDisabled is returned when RCON is disabled in the config.
var ErrRCONDisabled = fmt.Errorf("rcon desabilitado na configuração")

// defaultDialer opens a real RCON connection.
//
// A short net.DialTimeout (5s) pre-flight bounds the TCP connect step so a
// hung dial (firewall drop, unreachable host) can't hold executeLocked's
// mutex for gorcon's full internal timeout. Without this bound, the 10s
// backstop in Execute can block on c.mu.Lock() for the dial duration,
// pushing the effective cap to ~15s instead of the declared 10s (G6).
//
// Errors are returned unwrapped — executeLocked adds the "conectar rcon:"
// prefix consistently for both probe and rcon.Dial failures.
func defaultDialer(host string, port int, password string) (*rcon.Conn, error) {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	probe, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	_ = probe.Close()
	return rcon.Dial(addr, password)
}

// Execute runs an RCON command with the caller's ctx plus a 10s backstop timeout.
//
// The I/O runs in a goroutine so concurrent callers don't block on the mutex
// if the RCON server hangs (gorcon v1.3.5 has no context support). On ctx
// cancellation or the 10s backstop the current connection is closed to unblock
// the goroutine holding c.mu mid-I/O; the next caller dials a fresh connection.
//
// The mutex is still held inside executeLocked during dial/Execute I/O; full
// decoupling is non-trivial with gorcon v1.3.5 and left for a future fix.
// Respecting ctx.Done() ensures gRPC handler cancellation always breaks out
// of the select even if the underlying goroutine can't be interrupted.
func (c *Client) Execute(ctx context.Context, command string) (string, error) {
	if !c.enabled {
		return "", ErrRCONDisabled
	}

	// Capture the current connection so we can close it on timeout, unblocking
	// the goroutine holding c.mu mid-I/O.
	c.mu.Lock()
	currentConn := c.conn
	c.mu.Unlock()

	type result struct {
		resp string
		err  error
	}
	resultCh := make(chan result, 1)
	go func() {
		resp, err := c.executeLocked(command)
		resultCh <- result{resp, err}
	}()

	select {
	case r := <-resultCh:
		return r.resp, r.err
	case <-ctx.Done():
		// Cancellation: close the connection to unblock the goroutine holding the mutex.
		if currentConn != nil {
			_ = currentConn.Close()
		}
		c.mu.Lock()
		if c.conn == currentConn {
			c.conn = nil
		}
		c.mu.Unlock()
		// Best-effort: warn if the goroutine doesn't return shortly after cancellation.
		go func() {
			select {
			case <-resultCh:
			case <-time.After(2 * time.Second):
				log.Printf("rcon: execute goroutine still running after ctx cancel for command %q", command)
			}
		}()
		return "", ctx.Err()
	case <-time.After(10 * time.Second):
		// Timeout backstop: close the connection to unblock the goroutine holding the mutex.
		if currentConn != nil {
			_ = currentConn.Close()
		}
		// Invalidate the cache so the next caller dials fresh.
		c.mu.Lock()
		if c.conn == currentConn {
			c.conn = nil
		}
		c.mu.Unlock()
		return "", fmt.Errorf("rcon timeout (10s) executando %q", command)
	}
}

// executeLocked does the actual work of Execute while holding c.mu.
// Reuses a cached connection if valid; on connection error, dials a new one and retries once.
func (c *Client) executeLocked(command string) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Reuse the connection if used within the last cacheTTL seconds.
	if c.conn != nil && time.Since(c.lastUse) < c.cacheTTL {
		c.lastUse = time.Now()
		out, err := c.conn.Execute(command)
		if err == nil {
			return out, nil
		}
		// Connection died — close and reconnect.
		_ = c.conn.Close()
		c.conn = nil
	}

	conn, err := c.dialer(c.host, c.port, c.password)
	if err != nil {
		return "", fmt.Errorf("conectar rcon: %w", err)
	}
	c.conn = conn
	c.lastUse = time.Now()

	out, err := conn.Execute(command)
	if err != nil {
		// Close and clear the broken connection so the next caller dials fresh
		// instead of reusing a dead conn on its first attempt (G8).
		_ = c.conn.Close()
		c.conn = nil
		return "", fmt.Errorf("executar rcon %q: %w", command, err)
	}
	return out, nil
}

// Close closes the RCON connection if open. Safe for concurrent use.
func (c *Client) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil {
		err := c.conn.Close()
		c.conn = nil
		return err
	}
	return nil
}

// PlayerList queries the RCON "list" command and parses the response.
// Typical Minecraft response: "There are 2 of a max of 20 players online: player1, player2"
// Returns (players, max_players, error).
func (c *Client) PlayerList(ctx context.Context) ([]string, int, error) {
	out, err := c.Execute(ctx, "list")
	if err != nil {
		return nil, 0, err
	}
	return parseListResponse(out), parseMaxPlayers(out), nil
}

// parseListResponse extracts the player list from the RCON "list" response.
// Format: "There are N of a max of M players online: p1, p2, p3"
// Empty case: "There are 0 of a max of M players online: "
func parseListResponse(raw string) []string {
	idx := strings.LastIndex(raw, ":")
	if idx < 0 {
		return []string{}
	}
	rest := strings.TrimSpace(raw[idx+1:])
	if rest == "" {
		return []string{}
	}
	parts := strings.Split(rest, ",")
	players := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			players = append(players, p)
		}
	}
	return players
}

// parseMaxPlayers extracts the max player count from the "list" response.
func parseMaxPlayers(raw string) int {
	// Look for "max of N players".
	idx := strings.Index(raw, "max of ")
	if idx < 0 {
		return 0
	}
	rest := raw[idx+7:]
	end := strings.Index(rest, " ")
	if end < 0 {
		return 0
	}
	numStr := rest[:end]
	var n int
	_, err := fmt.Sscanf(numStr, "%d", &n)
	if err != nil {
		return 0
	}
	return n
}

// whitelistedCommands is a package-level immutable map to avoid reallocation on each IsCommandAllowed call.
var whitelistedCommands = map[string]bool{
	"say":        true,
	"list":       true,
	"tell":       true,
	"msg":        true,
	"w":          true,
	"title":      true,
	"effect":     true,
	"give":       true,
	"tp":         true,
	"teleport":   true,
	"time":       true,
	"weather":    true,
	"difficulty": true,
	"gamemode":   true,
	"save-all":   true,
	"save-off":   true,
	"save-on":    true,
}

// WhitelistedCommands returns a copy of the allowed-commands map.
// For hot-path lookups, prefer IsCommandAllowed (more efficient).
func WhitelistedCommands() map[string]bool {
	// Return a copy to prevent external mutation of the package-level map.
	out := make(map[string]bool, len(whitelistedCommands))
	for k, v := range whitelistedCommands {
		out[k] = v
	}
	return out
}

// IsCommandAllowed returns true if the command's first token is whitelisted.
func IsCommandAllowed(command string) bool {
	command = strings.TrimSpace(command)
	if command == "" {
		return false
	}
	parts := strings.Fields(command)
	if len(parts) == 0 {
		return false
	}
	cmd := strings.ToLower(parts[0])
	return whitelistedCommands[cmd]
}
