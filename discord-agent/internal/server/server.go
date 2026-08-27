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
        // defaultStreamDeadline bounds StreamConsole (longer because journalctl -f is client-cancellable).
        defaultStreamDeadline = 5 * time.Minute
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
}

// New returns a new Server, injecting the build version.
func New(cfg *config.Config, rconClient *rcon.Client, bus *events.Bus, version string) *Server {
        if version != "" {
                Version = version
        }
        return &Server{
                cfg:          cfg,
                rcon:         rconClient,
                bus:          bus,
                knownPlayers: make(map[string]bool),
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

// checkAuth applies per-IP rate limiting then validates the token.
func checkAuth(ctx context.Context, expected string) error {
        ip := clientIP(ctx)
        if ip != "" {
                if limiter := globalAuthLimiter.get(ip); limiter != nil {
                        if !limiter.Allow() {
                                log.Printf("auth rate limit excedido: ip=%s", ip)
                                return status.Error(codes.ResourceExhausted, "rate limit excedido, tente novamente em alguns segundos")
                        }
                }
        }
        return validateToken(ctx, expected, ip)
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

// authRateLimiter keeps a token-bucket rate.Limiter per IP.
// The limiters map is wiped every 5 minutes to bound memory (rate.Limiter
// exposes no last-use field, so per-entry eviction isn't possible).
type authRateLimiter struct {
        mu       sync.Mutex
        limiters map[string]*rate.Limiter
}

// newAuthRateLimiter creates a limiter (5 tokens/IP, refilling every 12s) and starts TTL eviction.
func newAuthRateLimiter() *authRateLimiter {
        a := &authRateLimiter{
                limiters: make(map[string]*rate.Limiter),
        }
        go func() {
                ticker := time.NewTicker(5 * time.Minute)
                defer ticker.Stop()
                for range ticker.C {
                        a.mu.Lock()
                        // Full reset — limiters are recreated on demand on the next request.
                        a.limiters = make(map[string]*rate.Limiter)
                        a.mu.Unlock()
                }
        }()
        return a
}

// globalAuthLimiter is used by interceptors that lack access to a *Server.
var globalAuthLimiter = newAuthRateLimiter()

// get returns the limiter for ip, creating it on first use. Returns nil for empty ip.
func (a *authRateLimiter) get(ip string) *rate.Limiter {
        if ip == "" {
                return nil
        }
        a.mu.Lock()
        defer a.mu.Unlock()
        l, exists := a.limiters[ip]
        if !exists {
                // Burst 5, 1 token every 12s = 5/min.
                l = rate.NewLimiter(rate.Every(12*time.Second), 5)
                a.limiters[ip] = l
        }
        return l
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

// StopServer runs `sudo systemctl stop <service>`, passing --signal=SIGTERM and --timeout=SECS
// so systemd respects the client's timeout (default 90s) instead of just the RPC deadline.
func (s *Server) StopServer(ctx context.Context, req *criasv1.StopRequest) (*criasv1.StopResponse, error) {
        timeoutSec := req.GetTimeoutSeconds()
        deadline := defaultRPCDeadline
        args := []string{"stop", s.cfg.Server.ServiceName}
        if timeoutSec > 0 {
                d := time.Duration(timeoutSec) * time.Second
                if d > 5*time.Minute {
                        d = 5 * time.Minute
                        timeoutSec = int32(d.Seconds())
                }
                deadline = d
                // Explicit SIGTERM + --timeout makes systemd honor the client timeout.
                args = []string{"stop", "--kill-who=main", "--signal=SIGTERM", fmt.Sprintf("--timeout=%d", timeoutSec), s.cfg.Server.ServiceName}
        }

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

// GetHealth checks if the game port is listening and (if enabled) RCON responds.
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

        resp.Healthy = resp.PortListening && (!s.cfg.Server.RCON.Enabled || resp.RconResponsive)
        if resp.Healthy {
                resp.Message = "healthy"
        } else {
                reasons := []string{}
                if !resp.PortListening {
                        reasons = append(reasons, fmt.Sprintf("porta %d não está em escuta", s.cfg.Server.ServerPort))
                }
                if s.cfg.Server.RCON.Enabled && !resp.RconResponsive {
                        reasons = append(reasons, "rcon indisponível")
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

// StreamConsole tails `journalctl -u <service> -f` and streams lines to the client.
//
// stdout is read in a goroutine so a blocked Read can still be interrupted by ctx cancellation.
// cmd.Cancel sends SIGTERM (with 5s WaitDelay) so client disconnect triggers graceful journalctl shutdown.
// Lines are capped at 64KB and tail_lines at 1000 to prevent memory exhaustion.
// Any buffered partial line is flushed on EOF to avoid silent data loss.
func (s *Server) StreamConsole(req *criasv1.StreamConsoleRequest, stream criasv1.ServerControl_StreamConsoleServer) error {
        // Apply a server-side max lifetime so a forgotten client can't keep a
        // journalctl -f process alive forever. The client is free to cancel earlier.
        ctx, cancel := withDeadline(stream.Context(), defaultStreamDeadline)
        defer cancel()

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

        // Goroutine reads stdout so select can respond to ctx.Done() even during a blocked Read.
        type readResult struct {
                data []byte
                err  error
        }
        readCh := make(chan readResult, 1)
        go func() {
                tmp := make([]byte, 4096)
                n, err := stdout.Read(tmp)
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
                                n, err := stdout.Read(tmp)
                                readCh <- readResult{data: append([]byte(nil), tmp[:n]...), err: err}
                        }()
                }
        }
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
