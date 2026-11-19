// Package rcon provides an RCON client for querying players and executing commands on the Minecraft server.
package rcon

import (
	"context"
	"fmt"
	"log"
	"net"
	"regexp"
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

	// mu guards conn and lastUse. It is NEVER held during dial or command
	// I/O (CR-27): a goroutine stuck in I/O must not keep other callers
	// from reading/replacing the shared connection.
	mu       sync.Mutex
	conn     *rcon.Conn
	lastUse  time.Time
	cacheTTL time.Duration

	// ioMu serializes send/receive on the shared connection. It CAN be held
	// while blocked in I/O, but only briefly: on Execute timeout the shared
	// connection is closed (abandonConn), which unblocks the reader and
	// releases ioMu (CR-27).
	ioMu sync.Mutex

	// dialMu serializes connection establishment so concurrent callers don't
	// open multiple connections. The dial itself runs OUTSIDE mu/ioMu and is
	// bounded by the dialer's internal deadlines (CR-27).
	dialMu sync.Mutex

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
// Every step is bounded by a deadline so a hung server (e.g. accepts TCP but
// never answers the auth handshake) can't stall the dialer forever (CR-27):
// net.Dialer{Timeout} bounds the TCP connect, and rcon.Open runs the
// handshake under gorcon's per-op deadlines (rcon.DefaultDeadline = 5s per
// read/write). Since the dial now happens outside the shared locks (see
// connForCommand), the pre-flight probe dial from the G6 fix is no longer
// needed — the TCP connect itself is bounded.
//
// Errors are returned unwrapped — connForCommand adds the "conectar rcon:"
// prefix consistently for both connect and auth failures.
func defaultDialer(host string, port int, password string) (*rcon.Conn, error) {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	d := net.Dialer{Timeout: 10 * time.Second}
	nc, err := d.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	// Explicit deadline: don't rely on gorcon's DefaultSettings staying at 5s.
	return rcon.Open(nc, password, rcon.SetDeadline(rcon.DefaultDeadline))
}

// Execute runs an RCON command with the caller's ctx plus a 10s backstop timeout.
//
// The work runs in a goroutine so concurrent callers don't block if the RCON
// server hangs (gorcon has no context support). On ctx cancellation or the
// 10s backstop, the CURRENT shared connection is closed and cleared
// (abandonConn) — this unblocks a goroutine stuck mid-I/O holding ioMu, and
// the next caller dials a fresh connection (CR-27). Unlike the old code, the
// connection is re-read at abandon time: the worker may have dialed one after
// Execute started, and that connection must also be reclaimable.
func (c *Client) Execute(ctx context.Context, command string) (string, error) {
	if !c.enabled {
		return "", ErrRCONDisabled
	}

	type result struct {
		resp string
		err  error
	}
	resultCh := make(chan result, 1)
	go func() {
		resp, err := c.perform(command)
		resultCh <- result{resp, err}
	}()

	select {
	case r := <-resultCh:
		return r.resp, r.err
	case <-ctx.Done():
		// Cancellation: abandon the shared connection to unblock the worker.
		c.abandonConn()
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
		// Timeout backstop: abandon the shared connection and invalidate the
		// cache so the next caller dials fresh.
		c.abandonConn()
		return "", fmt.Errorf("rcon timeout (10s) executando %q", command)
	}
}

// abandonConn closes whatever connection the client currently holds and
// clears it. Closing the conn interrupts any blocked read/write on it, which
// releases ioMu and lets the abandoned worker goroutine finish (CR-27).
func (c *Client) abandonConn() {
	c.mu.Lock()
	conn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
}

// perform executes the command, reusing the cached connection when possible
// and retrying once on a fresh connection when the cached one dies mid-I/O
// (same retry semantics as the old executeLocked).
func (c *Client) perform(command string) (string, error) {
	cached := c.cachedConn()
	if cached != nil {
		out, err := c.execOnConn(cached, command)
		if err == nil {
			return out, nil
		}
		// Cached connection died — fall through and retry once on a fresh one.
		conn, derr := c.connForCommand()
		if derr != nil {
			return "", derr
		}
		return c.execOnConn(conn, command)
	}

	conn, err := c.connForCommand()
	if err != nil {
		return "", err
	}
	return c.execOnConn(conn, command)
}

// execOnConn runs a single command on conn under ioMu. On I/O error the conn
// is closed and invalidated (if still the current one) so the next caller
// dials fresh instead of reusing a dead conn (G8).
func (c *Client) execOnConn(conn *rcon.Conn, command string) (string, error) {
	c.ioMu.Lock()
	out, err := conn.Execute(command)
	c.ioMu.Unlock()
	if err != nil {
		_ = conn.Close()
		c.mu.Lock()
		if c.conn == conn {
			c.conn = nil
		}
		c.mu.Unlock()
		return "", fmt.Errorf("executar rcon %q: %w", command, err)
	}
	return out, nil
}

// cachedConn returns the shared connection if it was used within cacheTTL
// (refreshing its last-use timestamp); nil otherwise.
func (c *Client) cachedConn() *rcon.Conn {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn != nil && time.Since(c.lastUse) < c.cacheTTL {
		c.lastUse = time.Now()
		return c.conn
	}
	return nil
}

// connForCommand returns a usable connection: the cached one if fresh, or a
// freshly dialed one. Dialing happens OUTSIDE mu/ioMu, bounded by the
// dialer's internal deadlines, so a hung dial can't wedge the client (CR-27).
func (c *Client) connForCommand() (*rcon.Conn, error) {
	if conn := c.cachedConn(); conn != nil {
		return conn, nil
	}

	// Serialize dialing so concurrent callers don't open multiple connections.
	// Blocking here is bounded: the dialer itself is deadline-bounded.
	c.dialMu.Lock()
	defer c.dialMu.Unlock()

	// Re-check: another goroutine may have dialed while we waited on dialMu.
	if conn := c.cachedConn(); conn != nil {
		return conn, nil
	}

	conn, err := c.dialer(c.host, c.port, c.password)
	if err != nil {
		return nil, fmt.Errorf("conectar rcon: %w", err)
	}
	c.mu.Lock()
	c.conn = conn
	c.lastUse = time.Now()
	c.mu.Unlock()
	return conn, nil
}

// Close closes the RCON connection if open. Safe for concurrent use.
func (c *Client) Close() error {
	c.mu.Lock()
	conn := c.conn
	c.conn = nil
	c.mu.Unlock()
	if conn != nil {
		return conn.Close()
	}
	return nil
}

// PlayerList queries the RCON "list" command and parses the response.
// Typical Minecraft response: "There are 2 of a max of 20 players online: player1, player2"
// Returns (players, max_players, error). A parse error means the player count
// is UNKNOWN — callers must NOT treat it as "0 players" (EXP-45).
func (c *Client) PlayerList(ctx context.Context) ([]string, int, error) {
	out, err := c.Execute(ctx, "list")
	if err != nil {
		return nil, 0, err
	}
	return parseListResponse(out)
}

// listCountPattern matches the count/max pair of the English "list" response:
// "There are 2 of a max of 20 players: ..." → "2 of a max of 20".
var listCountPattern = regexp.MustCompile(`(\d+)\s+of a max of\s+(\d+)`)

// intPattern extracts standalone integers — fallback for localized "list"
// responses that keep the same "count ... max ...:" shape (EXP-45).
var intPattern = regexp.MustCompile(`\d+`)

// parseListResponse extracts the player list and max players from the RCON
// "list" response, STRICTLY (EXP-45).
//
// Accepted formats (vanilla Java, across versions/locales):
//   - "There are 2 of a max of 20 players: Steve, Alex"   (1.13+)
//   - "There are 0 of a max of 20 players: "              (empty server)
//   - "There are 2 of a max of 20 players online: Steve, Alex"  (1.12-)
//   - localized variants with the same "count ... max ...:" shape.
//
// The declared count must match the number of parsed names. Anything that
// doesn't fit the format returns an ERROR (never an empty list with nil
// error) so callers treat the player count as UNKNOWN instead of "0 players"
// — the old behavior could stop a busy server via auto-shutdown.
func parseListResponse(raw string) ([]string, int, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, 0, fmt.Errorf("resposta 'list' vazia")
	}
	idx := strings.LastIndex(raw, ":")
	if idx < 0 {
		return nil, 0, fmt.Errorf("resposta 'list' sem separador ':': %q", raw)
	}
	head := raw[:idx]
	tail := strings.TrimSpace(raw[idx+1:])

	// Player names after the separator (comma-separated).
	players := []string{}
	if tail != "" {
		for _, p := range strings.Split(tail, ",") {
			if p = strings.TrimSpace(p); p != "" {
				players = append(players, p)
			}
		}
	}

	// Declared count + max: primary English pattern, else the first two
	// integers of the head (localized variants keep count before max).
	var declared, max int
	if m := listCountPattern.FindStringSubmatch(head); m != nil {
		declared, _ = strconv.Atoi(m[1])
		max, _ = strconv.Atoi(m[2])
	} else if nums := intPattern.FindAllString(head, -1); len(nums) >= 2 {
		declared, _ = strconv.Atoi(nums[0])
		max, _ = strconv.Atoi(nums[1])
	} else {
		return nil, 0, fmt.Errorf("resposta 'list' em formato desconhecido: %q", raw)
	}

	// Count coherence: the declared count must match the listed names.
	// (A truncated multi-packet RCON response also lands here — failing
	// closed is the safe direction.)
	if declared != len(players) {
		return nil, 0, fmt.Errorf("resposta 'list' incoerente: declara %d players mas lista %d nomes: %q", declared, len(players), raw)
	}
	return players, max, nil
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
