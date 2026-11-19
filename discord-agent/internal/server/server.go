// Package server implements the gRPC ServerControl and EventBus services.
package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/time/rate"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/config"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/rcon"

	criasv1 "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/proto"
)

// Absolute paths to external binaries (defense-in-depth against PATH injection).
const (
	sudoBin       = "/usr/bin/sudo"
	systemctlBin  = "/usr/bin/systemctl"
	journalctlBin = "/usr/bin/journalctl"
)

// RPC deadlines bound handler execution time.
const (
	// defaultRPCDeadline bounds synchronous RPCs.
	defaultRPCDeadline = 30 * time.Second
	// defaultStreamDeadline bounds SubscribeEvents (and StreamConsole when
	// features.console.stream_deadline_seconds is unset).
	defaultStreamDeadline = 5 * time.Minute
	// minStreamDeadline and maxStreamDeadline clamp the configurable console
	// stream deadline (features.console.stream_deadline_seconds, EXP-47).
	minStreamDeadline = 60 * time.Second
	maxStreamDeadline = 24 * time.Hour
	// maxTailLines caps StreamConsoleRequest.tail_lines (DoS prevention).
	maxTailLines = 1000
	// maxLineLen caps a single accumulated line (DoS prevention).
	maxLineLen = 65536
)

// Version is the agent version (overridden via ldflags in release builds).
var Version = "dev"

// Server implements criasv1.ServerControlServer and criasv1.EventBusServer.
type Server struct {
	criasv1.UnimplementedServerControlServer
	criasv1.UnimplementedEventBusServer

	cfg  *config.Config
	rcon *rcon.Client
	bus  *events.Bus

	mu           sync.Mutex
	knownPlayers map[string]bool // tracks join/leave transitions

	// checkUnitState is the systemd unit-state probe used by GetHealth;
	// overridable in tests (defaults to checkServiceState). EXP-53.
	checkUnitState func(ctx context.Context, service string) unitState
}

// New returns a new Server, injecting the build version.
func New(cfg *config.Config, rconClient *rcon.Client, bus *events.Bus, version string) *Server {
	if version != "" {
		Version = version
	}
	return &Server{
		cfg:            cfg,
		rcon:           rconClient,
		bus:            bus,
		knownPlayers:   make(map[string]bool),
		checkUnitState: checkServiceState,
	}
}

// withDeadline applies a server-side deadline, respecting any shorter client deadline.
func withDeadline(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if dl, ok := ctx.Deadline(); ok {
		clientRemaining := time.Until(dl)
		if clientRemaining <= d {
			return context.WithCancel(ctx)
		}
	}
	return context.WithTimeout(ctx, d)
}

// --- Auth Interceptors ---

// AuthInterceptor validates x-api-token and applies per-IP rate limiting on unary RPCs.
func AuthInterceptor(authToken string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := checkAuth(ctx, authToken); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// StreamAuthInterceptor validates x-api-token on stream RPCs.
func StreamAuthInterceptor(authToken string) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := checkAuth(ss.Context(), authToken); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}

// checkAuth validates the token FIRST and only applies rate limiting after
// (EXP-46). The old order (limit before validating) throttled legitimate bot
// traffic — several commands in sequence, or console streaming, hit the
// aggressive bucket (burst 5, 1 token/12s) and got ResourceExhausted even
// with a perfectly valid token.
//
//   - Valid token   → generous per-IP limiter (burst 60, refill 30/s). This is
//     only a runaway-loop guard: normal bot traffic (command bursts, event
//     subscriptions, console streaming) fits comfortably, while a client bug
//     looping at full speed still gets cut off.
//   - Invalid token → aggressive per-IP limiter (burst 5, 1 token/12s), i.e.
//     the brute-force protection stays as strict as before — invalid-auth
//     attempts are the only traffic subject to it.
func checkAuth(ctx context.Context, expected string) error {
	ip := clientIP(ctx)

	if err := validateToken(ctx, expected, ip); err != nil {
		// Invalid/missing token: aggressive brute-force limiter applies.
		// If the limiter map is full (limiterMapCap distinct IPs with no idle
		// entry to evict), fail CLOSED — brute-force protection must not be
		// bypassable by rotating source IPs (EXP-46).
		limiter, lerr := globalAuthLimiter.get(ip)
		if lerr != nil {
			log.Printf("auth rate limiter cheio, rejeitando: ip=%s", ip)
			return status.Error(codes.ResourceExhausted, "muitos endereços distintos sob rate limit, tente novamente mais tarde")
		}
		if limiter != nil && !limiter.Allow() {
			log.Printf("auth rate limit excedido: ip=%s", ip)
			return status.Error(codes.ResourceExhausted, "rate limit excedido, tente novamente em alguns segundos")
		}
		return err
	}

	// Valid token: only the generous limiter applies. If its map is full
	// (10k distinct AUTHENTICATED IPs), fail OPEN — the caller already proved
	// possession of the token, so rejecting authenticated traffic over map
	// pressure would recreate the EXP-46 outage in a different shape.
	limiter, lerr := globalAuthedLimiter.get(ip)
	if lerr == nil && limiter != nil && !limiter.Allow() {
		log.Printf("rate limit de tráfego autenticado excedido: ip=%s", ip)
		return status.Error(codes.ResourceExhausted, "rate limit de tráfego autenticado excedido")
	}
	return nil
}

// validateToken validates the x-api-token metadata, logging failures with the client IP.
func validateToken(ctx context.Context, expected string, ip string) error {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		log.Printf("auth falha: ip=%s reason=metadata_ausente", ip)
		return status.Error(codes.Unauthenticated, "metadata ausente")
	}
	tokens := md.Get("x-api-token")
	if len(tokens) == 0 {
		log.Printf("auth falha: ip=%s reason=token_ausente", ip)
		return status.Error(codes.Unauthenticated, "x-api-token metadata ausente")
	}
	// gRPC metadata allows duplicate x-api-token keys; reject any request
	// that supplies more than one value (G2).
	if len(tokens) > 1 {
		log.Printf("auth falha: ip=%s reason=token_duplicado count=%d", ip, len(tokens))
		return status.Error(codes.Unauthenticated, "token inválido")
	}
	// Constant-time comparison prevents timing attacks. Hash both sides to
	// a fixed length (32 bytes) before comparing so attackers can't infer the
	// expected token length via ConstantTimeCompare's early-exit on
	// unequal lengths (G3).
	sumExpected := sha256.Sum256([]byte(expected))
	sumProvided := sha256.Sum256([]byte(tokens[0]))
	if subtle.ConstantTimeCompare(sumExpected[:], sumProvided[:]) != 1 {
		log.Printf("auth falha: ip=%s reason=token_invalido", ip)
		return status.Error(codes.Unauthenticated, "token inválido")
	}
	return nil
}

// clientIP extracts the client IP (without port) from the gRPC peer context.
func clientIP(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return ""
	}
	if tcpAddr, ok := p.Addr.(*net.TCPAddr); ok {
		return tcpAddr.IP.String()
	}
	// Fallback for non-TCP peers (Unix socket, etc.): split host from "host:port".
	host, _, err := net.SplitHostPort(p.Addr.String())
	if err != nil {
		return p.Addr.String()
	}
	return host
}

// authRateLimiter keeps a token-bucket rate.Limiter per IP with a hard map
// cap. rate.Limiter exposes no last-use field, so each entry is wrapped with
// its own lastUsed timestamp; when the cap is hit, idle entries are evicted
// (EXP-46).
type authRateLimiter struct {
	mu       sync.Mutex
	limiters map[string]*ipLimiterEntry
	burst    int        // bucket size
	refill   rate.Limit // tokens per second
	cap      int        // max tracked IPs (limiterMapCap unless overridden in tests)
}

// ipLimiterEntry pairs a token bucket with its last-use time for eviction.
type ipLimiterEntry struct {
	limiter  *rate.Limiter
	lastUsed time.Time
}

// limiterMapCap bounds the per-IP limiters map (memory DoS protection):
// when full, entries idle for longer than limiterIdleTTL are evicted; if the
// map is still full, get fails and the caller fails closed (unauthenticated
// traffic only — see checkAuth) (EXP-46).
const limiterMapCap = 10000

// limiterIdleTTL is how long an entry must be idle before it becomes
// evictable under map pressure.
const limiterIdleTTL = 5 * time.Minute

// newAuthRateLimiter creates a per-IP limiter with the given burst/refill.
func newAuthRateLimiter(burst int, refill rate.Limit) *authRateLimiter {
	return &authRateLimiter{
		limiters: make(map[string]*ipLimiterEntry),
		burst:    burst,
		refill:   refill,
		cap:      limiterMapCap,
	}
}

var (
	// globalAuthLimiter guards INVALID-auth attempts (brute-force protection):
	// burst 5, 1 token every 12s ≈ 5/min per IP (EXP-46).
	globalAuthLimiter = newAuthRateLimiter(5, rate.Every(12*time.Second))
	// globalAuthedLimiter caps AUTHENTICATED traffic per IP: burst 60 with a
	// 30/s refill — generous enough for legitimate bot usage (command bursts,
	// console/event streaming), tight enough to stop a runaway client loop
	// (EXP-46; see checkAuth for the rationale).
	globalAuthedLimiter = newAuthRateLimiter(60, 30)
)

// errLimiterMapFull is returned by get when the map is at capacity and no
// idle entry could be evicted.
var errLimiterMapFull = errors.New("limiter map cheio")

// get returns the limiter for ip, creating it on first use. Returns
// (nil, nil) for an empty ip (no peer info — limiting is skipped, as before).
// Returns errLimiterMapFull when the map is at capacity and no idle entry
// can be evicted (EXP-46).
func (a *authRateLimiter) get(ip string) (*rate.Limiter, error) {
	if ip == "" {
		return nil, nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if e, ok := a.limiters[ip]; ok {
		e.lastUsed = now
		return e.limiter, nil
	}
	if len(a.limiters) >= a.cap {
		a.evictIdleLocked(now)
		if len(a.limiters) >= a.cap {
			return nil, errLimiterMapFull
		}
	}
	l := rate.NewLimiter(a.refill, a.burst)
	a.limiters[ip] = &ipLimiterEntry{limiter: l, lastUsed: now}
	return l, nil
}

// evictIdleLocked removes entries idle for longer than limiterIdleTTL.
func (a *authRateLimiter) evictIdleLocked(now time.Time) {
	for ip, e := range a.limiters {
		if now.Sub(e.lastUsed) > limiterIdleTTL {
			delete(a.limiters, ip)
		}
	}
}

// --- ServerControl RPCs ---

// StartServer runs `sudo systemctl start <service>`. With force=true on an active service, it restarts instead.
func (s *Server) StartServer(ctx context.Context, req *criasv1.StartRequest) (*criasv1.StartResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	if req.GetForce() && s.isServiceActive(ctx, s.cfg.Server.ServiceName) {
		out, err := s.runSystemctl(ctx, "restart", s.cfg.Server.ServiceName)
		if err != nil {
			s.bus.Publish(events.Event{
				EventType:   "HealthWarning",
				ServiceName: s.cfg.Server.ServiceName,
				Stack:       s.cfg.Server.Stack,
				Metadata:    map[string]string{"reason": "force_restart_failed", "error": err.Error(), "output": out},
			})
			return nil, systemctlStatusError([]string{"restart", s.cfg.Server.ServiceName}, out, err)
		}
		s.bus.Publish(events.Event{
			EventType:   "ServerStarted",
			ServiceName: s.cfg.Server.ServiceName,
			Stack:       s.cfg.Server.Stack,
			Metadata:    map[string]string{"force": "true", "reason": "force_restart"},
		})
		return &criasv1.StartResponse{
			Ok:          true,
			Message:     "servidor reiniciado (force=true)",
			ServiceName: s.cfg.Server.ServiceName,
		}, nil
	}

	out, err := s.runSystemctl(ctx, "start", s.cfg.Server.ServiceName)
	if err != nil {
		s.bus.Publish(events.Event{
			EventType:   "HealthWarning",
			ServiceName: s.cfg.Server.ServiceName,
			Stack:       s.cfg.Server.Stack,
			Metadata:    map[string]string{"reason": "start_failed", "error": err.Error(), "output": out},
		})
		return nil, systemctlStatusError([]string{"start", s.cfg.Server.ServiceName}, out, err)
	}

	s.bus.Publish(events.Event{
		EventType:   "ServerStarted",
		ServiceName: s.cfg.Server.ServiceName,
		Stack:       s.cfg.Server.Stack,
		Metadata:    map[string]string{"force": strconv.FormatBool(req.GetForce())},
	})

	return &criasv1.StartResponse{
		Ok:          true,
		Message:     "servidor iniciado",
		ServiceName: s.cfg.Server.ServiceName,
	}, nil
}

// StopServer runs `sudo systemctl stop <service>`. The client timeout (if
// any) only extends the gRPC deadline; it is NOT forwarded to systemctl:
// systemd's CLI has no --timeout option (systemd 257 rejects it with
// "unrecognized option"), and `systemctl stop` already sends SIGTERM to the
// main process honoring the unit's TimeoutStopSec.
func (s *Server) StopServer(ctx context.Context, req *criasv1.StopRequest) (*criasv1.StopResponse, error) {
	timeoutSec := req.GetTimeoutSeconds()
	deadline := defaultRPCDeadline
	if timeoutSec > 0 {
		d := time.Duration(timeoutSec) * time.Second
		if d > 5*time.Minute {
			d = 5 * time.Minute
			timeoutSec = int32(d.Seconds())
		}
		deadline = d
	}

	args := []string{"stop", s.cfg.Server.ServiceName}

	ctx, cancel := withDeadline(ctx, deadline)
	defer cancel()

	out, err := s.runSystemctlArgs(ctx, args)
	if err != nil {
		return nil, systemctlStatusError(args, out, err)
	}

	s.bus.Publish(events.Event{
		EventType:   "ServerStopped",
		ServiceName: s.cfg.Server.ServiceName,
		Stack:       s.cfg.Server.Stack,
		// Report the clamped timeout so consumers don't see a value (e.g. 600)
		// that doesn't match the --timeout actually passed to systemctl (G13).
		Metadata: map[string]string{"timeout_seconds": fmt.Sprintf("%d", timeoutSec)},
	})

	return &criasv1.StopResponse{
		Ok:          true,
		Message:     "servidor parado",
		ServiceName: s.cfg.Server.ServiceName,
	}, nil
}

// RestartServer runs `sudo systemctl restart <service>`.
func (s *Server) RestartServer(ctx context.Context, req *criasv1.RestartRequest) (*criasv1.RestartResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	out, err := s.runSystemctl(ctx, "restart", s.cfg.Server.ServiceName)
	if err != nil {
		return nil, systemctlStatusError([]string{"restart", s.cfg.Server.ServiceName}, out, err)
	}

	s.bus.Publish(events.Event{
		EventType:   "ServerStarted",
		ServiceName: s.cfg.Server.ServiceName,
		Stack:       s.cfg.Server.Stack,
		Metadata:    map[string]string{"reason": "restart"},
	})

	return &criasv1.RestartResponse{
		Ok:          true,
		Message:     "servidor reiniciado",
		ServiceName: s.cfg.Server.ServiceName,
	}, nil
}

// GetStatus returns consolidated status: systemd state, RCON players, resource usage.
func (s *Server) GetStatus(ctx context.Context, req *criasv1.GetStatusRequest) (*criasv1.StatusResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	active := s.isServiceActive(ctx, s.cfg.Server.ServiceName)

	resp := &criasv1.StatusResponse{
		ServiceName:  s.cfg.Server.ServiceName,
		Stack:        s.cfg.Server.Stack,
		Version:      Version,
		HardwareTier: s.cfg.Server.HardwareTier,
	}

	if active {
		resp.ServiceActive = true
		resp.UptimeSeconds = s.getServiceUptime(ctx, s.cfg.Server.ServiceName)

		resp.MemoryUsedMb = s.getServiceMemoryUsedMB(ctx, s.cfg.Server.ServiceName)
		resp.MemoryMaxMb = s.getServiceMemoryMaxMB(ctx, s.cfg.Server.ServiceName)

		// Best-effort RCON player list.
		if s.rcon != nil {
			players, maxPlayers, err := s.rcon.PlayerList(ctx)
			if err == nil {
				resp.Players = players
				resp.PlayerCount = int32(len(players))
				resp.MaxPlayers = int32(maxPlayers)
			}
		}
	}

	return resp, nil
}

// GetHealth checks the game systemd unit state, whether the game port is
// listening and (if enabled) whether RCON responds.
//
// EXP-53: port+RCON alone can report healthy when the game unit is STOPPED
// and some other process holds the game port — Healthy now also requires the
// unit to be `active`. If the systemctl probe fails entirely (no systemd,
// binary missing), we fall back to the legacy port+RCON behavior and surface
// the unknown unit state in the message + log instead of guessing.
func (s *Server) GetHealth(ctx context.Context, req *criasv1.GetHealthRequest) (*criasv1.HealthResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	resp := &criasv1.HealthResponse{
		ServiceName: s.cfg.Server.ServiceName,
		Port:        int32(s.cfg.Server.ServerPort),
	}

	if s.cfg.Server.ServerPort > 0 {
		addr := fmt.Sprintf("127.0.0.1:%d", s.cfg.Server.ServerPort)
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			resp.PortListening = true
			_ = conn.Close()
		}
	}

	// If RCON is enabled, probe responsiveness. rcon.NewClient always
	// returns a non-nil client, so the s.rcon != nil guard alone is
	// insufficient — we must also check the config flag (G4).
	if s.rcon != nil && s.cfg.Server.RCON.Enabled {
		_, _, err := s.rcon.PlayerList(ctx)
		if err == nil {
			resp.RconResponsive = true
		}
	}

	// EXP-53: require the game unit itself to be active. HealthResponse has
	// no dedicated proto field for it, so the state is folded into the message
	// string (and logged when unknown).
	stateFn := s.checkUnitState
	if stateFn == nil {
		stateFn = checkServiceState
	}
	unitState := stateFn(ctx, s.cfg.Server.ServiceName)

	resp.Healthy = resp.PortListening && (!s.cfg.Server.RCON.Enabled || resp.RconResponsive)
	switch unitState {
	case unitStateActive:
		// healthy stays as computed from port+RCON
	case unitStateInactive:
		resp.Healthy = false
	default: // unitStateUnknown — systemctl probe failed entirely
		// Fall back to the legacy port+RCON verdict, but don't hide it.
		log.Printf("GetHealth: estado da unit %q desconhecido (systemctl is-active falhou) — usando apenas porta+rcon", s.cfg.Server.ServiceName)
	}

	if resp.Healthy {
		resp.Message = "healthy"
		if unitState == unitStateUnknown {
			resp.Message = "healthy (estado da unit systemd desconhecido)"
		}
	} else {
		reasons := []string{}
		if !resp.PortListening {
			reasons = append(reasons, fmt.Sprintf("porta %d não está em escuta", s.cfg.Server.ServerPort))
		}
		if s.cfg.Server.RCON.Enabled && !resp.RconResponsive {
			reasons = append(reasons, "rcon indisponível")
		}
		if unitState == unitStateInactive {
			reasons = append(reasons, "unit systemd não está ativa")
		} else if unitState == unitStateUnknown {
			reasons = append(reasons, "estado da unit systemd desconhecido")
		}
		resp.Message = strings.Join(reasons, "; ")
	}

	return resp, nil
}

// SendRconCommand executes a whitelisted RCON command.
func (s *Server) SendRconCommand(ctx context.Context, req *criasv1.SendRconCommandRequest) (*criasv1.SendRconCommandResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	command := strings.TrimSpace(req.GetCommand())
	if command == "" {
		return nil, status.Error(codes.InvalidArgument, "comando vazio")
	}

	if !rcon.IsCommandAllowed(command) {
		return nil, status.Errorf(codes.PermissionDenied, "comando %q não está na whitelist", strings.Fields(command)[0])
	}

	if s.rcon == nil || !s.cfg.Server.RCON.Enabled {
		return nil, status.Error(codes.FailedPrecondition, "rcon desabilitado na configuração")
	}

	out, err := s.rcon.Execute(ctx, command)
	if err != nil {
		return nil, rconStatusError(err)
	}

	return &criasv1.SendRconCommandResponse{
		Ok:     true,
		Output: out,
	}, nil
}

// consoleStreamDeadline returns the configured StreamConsole max lifetime
// from features.console.stream_deadline_seconds (EXP-47), clamped to
// [minStreamDeadline, maxStreamDeadline] and falling back to
// defaultStreamDeadline when unset (e.g. Servers built with a hand-made
// config in tests).
func (s *Server) consoleStreamDeadline() time.Duration {
	secs := s.cfg.Features.Console.StreamDeadlineSeconds
	if secs <= 0 {
		return defaultStreamDeadline
	}
	d := time.Duration(secs) * time.Second
	if d < minStreamDeadline {
		return minStreamDeadline
	}
	if d > maxStreamDeadline {
		return maxStreamDeadline
	}
	return d
}

// consoleDeadlineMarker builds the final line sent when the server-side
// stream deadline fires, so the client can distinguish a deadline-close from
// an error-close and reconnect automatically (EXP-47).
func consoleDeadlineMarker(deadline time.Duration) string {
	return fmt.Sprintf("[crias-agent] console stream deadline reached (%ds); reconnect to continue", int(deadline.Seconds()))
}

// streamConsoleLines pumps journalctl output from r to the client, line by
// line, until r hits EOF, the ctx ends or a Send fails. When the ctx ends
// because the SERVER-SIDE deadline fired (deadlineFired, set by the caller's
// timer before it cancels the ctx), the buffered partial line is flushed and
// the deadline marker is emitted so the client can tell a deadline-close from
// an error-close and reconnect (EXP-47). Split from StreamConsole so the
// marker mechanism is unit-testable without journalctl.
func streamConsoleLines(ctx context.Context, r io.Reader, stream criasv1.ServerControl_StreamConsoleServer, deadline time.Duration, deadlineFired *atomic.Bool) error {
	// Goroutine reads stdout so select can respond to ctx.Done() even during a blocked Read.
	type readResult struct {
		data []byte
		err  error
	}
	readCh := make(chan readResult, 1)
	go func() {
		tmp := make([]byte, 4096)
		n, err := r.Read(tmp)
		readCh <- readResult{data: append([]byte(nil), tmp[:n]...), err: err}
	}()

	buf := make([]byte, 0, 8192)

	// flushRemaining sends any buffered partial line as a final ConsoleLine
	// so a journalctl killed mid-line doesn't lose data silently.
	flushRemaining := func() error {
		if len(buf) == 0 {
			return nil
		}
		line := string(buf)
		buf = buf[:0]
		return stream.Send(&criasv1.ConsoleLine{
			Line:          strings.TrimRight(line, "\r"),
			TimestampUnix: time.Now().Unix(),
		})
	}
	for {
		select {
		case <-ctx.Done():
			// EXP-47: when OUR deadline fired (not a client cancellation), emit
			// the marker line so the client knows to reconnect — the Python bot
			// presents the console session as continuous and reopens on this.
			if deadlineFired.Load() {
				if err := flushRemaining(); err != nil {
					return err
				}
				if err := stream.Send(&criasv1.ConsoleLine{
					Line:          consoleDeadlineMarker(deadline),
					TimestampUnix: time.Now().Unix(),
				}); err != nil {
					return err
				}
				log.Printf("StreamConsole: deadline de %s atingido, fechando stream (cliente deve reconectar)", deadline)
			}
			return ctx.Err()
		case res := <-readCh:
			if res.err != nil && !errors.Is(res.err, io.EOF) && len(res.data) == 0 {
				return status.Errorf(codes.Internal, "ler journalctl: %v", res.err)
			}
			if len(res.data) > 0 {
				buf = append(buf, res.data...)
				// Cap lines without newlines to prevent unbounded buffer growth.
				if len(buf) > maxLineLen {
					return status.Error(codes.ResourceExhausted, "linha de log excede 64KB sem newline")
				}
				for {
					idx := bytes.IndexByte(buf, '\n')
					if idx < 0 {
						break
					}
					line := string(buf[:idx])
					buf = buf[idx+1:]
					if err := stream.Send(&criasv1.ConsoleLine{
						Line:          strings.TrimRight(line, "\r"),
						TimestampUnix: time.Now().Unix(),
					}); err != nil {
						return err
					}
				}
			}
			if errors.Is(res.err, io.EOF) {
				if err := flushRemaining(); err != nil {
					return err
				}
				return nil
			}
			if res.err != nil {
				return status.Errorf(codes.Internal, "ler journalctl: %v", res.err)
			}
			// Schedule the next read in a goroutine to continue the pattern.
			go func() {
				tmp := make([]byte, 4096)
				n, err := r.Read(tmp)
				readCh <- readResult{data: append([]byte(nil), tmp[:n]...), err: err}
			}()
		}
	}
}

// StreamConsole tails `journalctl -u <service> -f` and streams lines to the client.
//
// stdout is read in a goroutine so a blocked Read can still be interrupted by ctx cancellation.
// cmd.Cancel sends SIGTERM (with 5s WaitDelay) so client disconnect triggers graceful journalctl shutdown.
// Lines are capped at 64KB and tail_lines at 1000 to prevent memory exhaustion.
// Any buffered partial line is flushed on EOF to avoid silent data loss.
//
// EXP-47: the server-side max lifetime is configurable via
// features.console.stream_deadline_seconds (default 300s). When the deadline
// fires, a marker line is emitted before the stream closes so the client can
// tell a deadline-close from an error-close and reopen the session.
func (s *Server) StreamConsole(req *criasv1.StreamConsoleRequest, stream criasv1.ServerControl_StreamConsoleServer) error {
	// Apply a server-side max lifetime so a forgotten client can't keep a
	// journalctl -f process alive forever. The client is free to cancel earlier
	// (its cancellation — including a shorter client-side deadline — propagates
	// through stream.Context()).
	deadline := s.consoleStreamDeadline()
	ctx, cancel := context.WithCancel(stream.Context())
	defer cancel()

	// deadlineFired distinguishes OUR deadline from a client-side cancellation.
	// The timer is the ONLY source of the server-side deadline: it stores the
	// flag and only then cancels the ctx, so a cancelled ctx observed with no
	// client cancellation is guaranteed (happens-before: atomic store → cancel
	// → channel close) to see the flag set. A separate context.WithTimeout
	// racing the timer could close the stream microseconds before the flag
	// store and silently skip the reconnect marker (EXP-47).
	var deadlineFired atomic.Bool
	timer := time.AfterFunc(deadline, func() {
		deadlineFired.Store(true)
		cancel()
	})
	defer timer.Stop()

	tailLines := int(req.GetTailLines())
	if tailLines <= 0 {
		tailLines = 50
	}
	if tailLines > maxTailLines {
		tailLines = maxTailLines
	}

	// journalctl -u minecraft -f -n 50 --output=cat --no-pager
	args := []string{
		"-u", s.cfg.Server.ServiceName,
		"-f",
		"-n", fmt.Sprintf("%d", tailLines),
		"--output=cat",
		"--no-pager",
	}
	cmd := exec.CommandContext(ctx, journalctlBin, args...)
	// LC_ALL=C forces locale-independent output.
	cmd.Env = append(cmd.Environ(), "LC_ALL=C", "LANG=C")
	// cmd.Cancel sends SIGTERM instead of immediate SIGKILL on ctx cancellation;
	// WaitDelay escalates to SIGKILL after 5s if journalctl doesn't exit.
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return cmd.Process.Signal(syscall.SIGTERM)
	}
	cmd.WaitDelay = 5 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return status.Errorf(codes.Internal, "criar pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		return status.Errorf(codes.Internal, "iniciar journalctl: %v", err)
	}

	// stopProc gracefully shuts down journalctl on normal handler return
	// (covers cases where ctx isn't cancelled but the handler exits, e.g., stream.Send error).
	stopProc := func() {
		if cmd.Process == nil {
			return
		}
		_ = cmd.Process.Signal(syscall.SIGTERM)
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	}
	defer stopProc()

	return streamConsoleLines(ctx, stdout, stream, deadline, &deadlineFired)
}

// --- EventBus RPCs ---

// SubscribeEvents streams events to the client until ctx is cancelled or the
// server-side max lifetime (defaultStreamDeadline) elapses.
func (s *Server) SubscribeEvents(req *criasv1.SubscribeEventsRequest, stream criasv1.EventBus_SubscribeEventsServer) error {
	// Bound the stream lifetime so a forgotten client can't hold a subscriber forever.
	ctx, ctxCancel := withDeadline(stream.Context(), defaultStreamDeadline)
	defer ctxCancel()

	ch, cancel := s.bus.Subscribe(req.GetEventTypes())
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-ch:
			if !ok {
				return nil
			}
			if err := stream.Send(eventToProto(ev)); err != nil {
				return err
			}
		}
	}
}

// --- Helpers ---

// runSystemctl runs `sudo systemctl <op> <service>` and returns combined output.
func (s *Server) runSystemctl(ctx context.Context, op string, service string) (string, error) {
	return s.runSystemctlArgs(ctx, []string{op, service})
}

// runSystemctlArgs runs `sudo systemctl <args...>` with LC_ALL=C for deterministic output.
func (s *Server) runSystemctlArgs(ctx context.Context, args []string) (string, error) {
	fullArgs := append([]string{systemctlBin}, args...)
	cmd := exec.CommandContext(ctx, sudoBin, fullArgs...)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("sudo systemctl %s: %w (output: %s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// systemctlStatusError maps a systemctl error to a specific gRPC code:
//   - exit 4/5 or "not loaded"/"could not be found" → NotFound
//   - ctx.DeadlineExceeded → DeadlineExceeded
//   - other → Internal
func systemctlStatusError(args []string, out string, err error) error {
	if err == nil {
		return nil
	}
	outTrim := strings.TrimSpace(out)
	opStr := strings.Join(args, " ")

	// systemctl exit 4 = unit not loaded, exit 5 = unit does not exist.
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		if code == 4 || code == 5 {
			return status.Errorf(codes.NotFound, "serviço não encontrado (exit %d): sudo systemctl %s (output: %s)", code, opStr, outTrim)
		}
	}

	// Typical LC_ALL=C output: "Failed to stop X.service: Unit X.service not loaded."
	// or "Unit X.service could not be found."
	if strings.Contains(outTrim, "not loaded") ||
		strings.Contains(outTrim, "could not be found") ||
		strings.Contains(outTrim, "Failed to get D-Bus connection") {
		return status.Errorf(codes.NotFound, "serviço não encontrado: sudo systemctl %s (output: %s)", opStr, outTrim)
	}

	// RPC deadline hit.
	if errors.Is(err, context.DeadlineExceeded) {
		return status.Errorf(codes.DeadlineExceeded, "systemctl timeout: sudo systemctl %s (output: %s)", opStr, outTrim)
	}

	return status.Errorf(codes.Internal, "falha sudo systemctl %s: %v (output: %s)", opStr, err, outTrim)
}

// rconStatusError maps an RCON error to a specific gRPC code:
//   - "conectar rcon" → Unavailable (game server didn't accept the connection)
//   - "rcon timeout" → DeadlineExceeded
//   - other → Internal
func rconStatusError(err error) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if strings.Contains(msg, "conectar rcon") {
		return status.Error(codes.Unavailable, "rcon indisponível: "+msg)
	}
	if strings.Contains(msg, "rcon timeout") {
		return status.Error(codes.DeadlineExceeded, msg)
	}
	return status.Error(codes.Internal, "rcon: "+msg)
}

// unitState is the tri-state result of querying the game unit's state (EXP-53).
type unitState int

const (
	// unitStateUnknown: the systemctl probe failed entirely (binary missing,
	// no systemd, ...) — the unit state could not be determined.
	unitStateUnknown unitState = iota
	// unitStateActive: `systemctl is-active` reports the unit as active.
	unitStateActive
	// unitStateInactive: systemctl answered with a non-active state
	// (inactive, failed, activating, ...).
	unitStateInactive
)

// checkServiceState queries `systemctl is-active <service>` and classifies the
// outcome into a unitState (EXP-53). Like isServiceActive, it runs systemctl
// directly (read-only query — no sudo needed; the sudoers allowlist covers
// the privileged start/stop/restart ops).
func checkServiceState(ctx context.Context, service string) unitState {
	cmd := exec.CommandContext(ctx, systemctlBin, "is-active", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	return classifyUnitState(string(out), err)
}

// classifyUnitState classifies the output+error of `systemctl is-active`:
// exit 0 → active; a printed non-active state string → inactive; anything
// else (no usable output) → unknown (the call itself failed). Split from
// checkServiceState so the parsing is unit-testable (EXP-53).
func classifyUnitState(out string, err error) unitState {
	if err == nil {
		// Exit 0 means the unit is active.
		return unitStateActive
	}
	switch strings.ToLower(strings.TrimSpace(out)) {
	case "active":
		// Defensive: some systemd versions may print "active" with a nonzero
		// exit code (e.g. when the ctx deadline races the call).
		return unitStateActive
	case "inactive", "failed", "activating", "deactivating", "reloading", "maintenance", "unknown":
		// "unknown" is what is-active prints for a not-loaded/nonexistent
		// unit — the game server can't be running under it, so treat it as
		// inactive (the safe direction for GetHealth).
		return unitStateInactive
	default:
		// Empty/garbage output → systemctl itself failed (not installed,
		// no D-Bus, unit name rejected, ...).
		return unitStateUnknown
	}
}

// isServiceActive returns true if `systemctl is-active --quiet <service>` exits 0.
func (s *Server) isServiceActive(ctx context.Context, service string) bool {
	cmd := exec.CommandContext(ctx, systemctlBin, "is-active", "--quiet", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	return cmd.Run() == nil
}

// getServiceUptime returns uptime in seconds from ExecMainStartTimestamp.
// LC_ALL=C ensures deterministic timestamp parsing across locales.
func (s *Server) getServiceUptime(ctx context.Context, service string) int64 {
	cmd := exec.CommandContext(ctx, systemctlBin, "show", "-p", "ExecMainStartTimestamp", "--value", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	ts := strings.TrimSpace(string(out))
	if ts == "" || ts == "0" {
		return 0
	}
	// Parse without TZ abbreviation (breaks in non-UTC locales); interpret in host local time.
	t, err := time.ParseInLocation("Mon 2006-01-02 15:04:05", ts, time.Local)
	if err != nil {
		// Fallback: layout with MST for compatibility.
		t, err = time.Parse("Mon 2006-01-02 15:04:05 MST", ts)
		if err != nil {
			return 0
		}
	}
	uptime := int64(time.Since(t).Seconds())
	// Clock skew or a future-dated ExecMainStartTimestamp could yield a
	// negative uptime; clamp to 0 to avoid confusing callers (G7).
	if uptime < 0 {
		uptime = 0
	}
	return uptime
}

// getServiceMemoryUsedMB returns the service's resident memory in MB.
func (s *Server) getServiceMemoryUsedMB(ctx context.Context, service string) int64 {
	return s.getServicePropertyMB(ctx, service, "MemoryCurrent")
}

// getServiceMemoryMaxMB returns the service's MemoryMax in MB.
func (s *Server) getServiceMemoryMaxMB(ctx context.Context, service string) int64 {
	return s.getServicePropertyMB(ctx, service, "MemoryMax")
}

// getServicePropertyMB reads a systemd memory property and converts it to MB.
func (s *Server) getServicePropertyMB(ctx context.Context, service string, prop string) int64 {
	cmd := exec.CommandContext(ctx, systemctlBin, "show", "-p", prop, "--value", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	raw := strings.TrimSpace(string(out))
	// MemoryCurrent/MemoryMax may be "[not set]", "0", or "infinity".
	if raw == "" || raw == "[not set]" || raw == "infinity" {
		return 0
	}
	bytes, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || bytes <= 0 {
		return 0
	}
	return bytes / (1024 * 1024)
}

// eventToProto converts an events.Event to a criasv1.ServerEvent.
func eventToProto(ev events.Event) *criasv1.ServerEvent {
	return &criasv1.ServerEvent{
		EventId:       ev.EventID,
		EventType:     ev.EventType,
		TimestampUnix: ev.TimestampUnix,
		ServiceName:   ev.ServiceName,
		Stack:         ev.Stack,
		Metadata:      ev.Metadata,
	}
}
