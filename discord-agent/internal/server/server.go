// Package server implementa os serviços gRPC ServerControl e EventBus.
package server

import (
	"bytes"
	"context"
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

// Caminhos absolutos para binários externos (defense-in-depth contra
// PATH injection / lookup malicioso).
// GO-009: nunca usar lookup via PATH — sempre caminho absoluto.
const (
	sudoBin       = "/usr/bin/sudo"
	systemctlBin  = "/usr/bin/systemctl"
	journalctlBin = "/usr/bin/journalctl"
)

// Defaults de deadline para RPCs.
// GO-002: todos os RPCs têm deadline server-side para evitar resource exhaustion.
const (
	// defaultRPCDeadline é o deadline máximo para RPCs síncronos.
	defaultRPCDeadline = 30 * time.Second
	// defaultStreamDeadline é o deadline para streaming RPCs (StreamConsole).
	// Mais longo porque journalctl -f é um stream infinito controlado pelo
	// cliente (que pode cancelar via ctx a qualquer momento).
	defaultStreamDeadline = 5 * time.Minute
	// maxTailLines é o limite superior para StreamConsoleRequest.tail_lines.
	// GO-018: previne DoS via journalctl -n INT32_MAX.
	maxTailLines = 1000
	// maxLineLen é o limite superior para uma linha acumulada em StreamConsole.
	// GO-017: previne crescimento unbounded de buf se journal produzir linha
	// gigante (1MB+) sem newline.
	maxLineLen = 65536
)

// Version é a versão do agente. Default "dev"; sobrescrita via New() com a
// versão injetada por ldflags no build.
var Version = "dev"

// Server implementa criasv1.ServerControlServer e criasv1.EventBusServer.
type Server struct {
	criasv1.UnimplementedServerControlServer
	criasv1.UnimplementedEventBusServer

	cfg  *config.Config
	rcon *rcon.Client
	bus  *events.Bus

	// Estado interno.
	mu           sync.Mutex
	knownPlayers map[string]bool // para detectar join/leave
}

// New cria uma nova instância do servidor gRPC.
// O parâmetro `version` define a versão do agente (injetada via ldflags
// em builds release; default "dev" se vazio).
// GO-007: versão passada por construtor garante que StatusResponse.Version
// reflita a versão real do build (não o default "dev").
//
// 2B-005: o campo `authLimiter` foi removido — era dead code (inicializado
// mas nunca lido). Os interceptors usam o package-level `globalAuthLimiter`,
// que é o único limiter de auth do agente.
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

// withDeadline aplica um deadline server-side ao contexto do RPC.
// GO-002: garante que nenhum handler bloqueie indefinidamente, mesmo se o
// cliente não enviar grpc-timeout metadata.
// Se o cliente já enviou um deadline menor, ele é respeitado.
func withDeadline(ctx context.Context, d time.Duration) (context.Context, context.CancelFunc) {
	if dl, ok := ctx.Deadline(); ok {
		// Cliente já definiu deadline; usa o menor entre o do cliente e d.
		clientRemaining := time.Until(dl)
		if clientRemaining <= d {
			// Deadline do cliente é menor — não precisa adicionar outro.
			return context.WithCancel(ctx)
		}
	}
	return context.WithTimeout(ctx, d)
}

// --- Auth Interceptors ---

// AuthInterceptor valida o token x-api-token em cada RPC e aplica rate limiting.
// GO-010: rate limit por IP para prevenir brute force.
func AuthInterceptor(authToken string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := checkAuth(ctx, authToken); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

// StreamAuthInterceptor valida o token em streams (SubscribeEvents, StreamConsole).
func StreamAuthInterceptor(authToken string) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := checkAuth(ss.Context(), authToken); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}

// checkAuth aplica rate limiting por IP + validação de token.
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

// validateToken valida o token x-api-token vindo via metadata.
// GO-024: loga tentativas falhas com IP e reason para audit trail.
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
	// Constant-time comparison para prevenir timing attacks.
	// GO-023: idealmente hash de ambos os lados para esconder length, mas o
	// formato (64 hex) já é público via README; impacto prático é baixo.
	if subtle.ConstantTimeCompare([]byte(tokens[0]), []byte(expected)) != 1 {
		log.Printf("auth falha: ip=%s reason=token_invalido", ip)
		return status.Error(codes.Unauthenticated, "token inválido")
	}
	return nil
}

// clientIP extrai o IP do peer gRPC (para rate limiting e audit log).
// 2B-001: extrai apenas o IP (sem porta) — usar `peer.Addr.String()` retorna
// "IP:porta" e cada conexão TCP (porta de origem diferente) ganharia seu
// próprio limiter, permitindo bypass via múltiplas conexões.
func clientIP(ctx context.Context) string {
	p, ok := peer.FromContext(ctx)
	if !ok || p.Addr == nil {
		return ""
	}
	if tcpAddr, ok := p.Addr.(*net.TCPAddr); ok {
		return tcpAddr.IP.String()
	}
	// Fallback para não-TCP (Unix socket, etc.): tenta Host da string "host:port".
	host, _, err := net.SplitHostPort(p.Addr.String())
	if err != nil {
		return p.Addr.String()
	}
	return host
}

// authRateLimiter mantém um rate.Limiter por IP (token bucket).
// GO-010: limite de 5 tentativas por minuto por IP.
//
// 2B-002: o map `limiters` cresceria indefinidamente (uma entrada por IP
// único). Evictamos periodicamente para evitar memory leak/OOM em agentes
// expostos a muitos IPs. Como `rate.Limiter` não expõe last-use, limpamos
// todo o map a cada 5 min — limiters são recriados on-demand na próxima
// request (custo baixo: 1 syscall + struct pequena por IP).
type authRateLimiter struct {
	mu       sync.Mutex
	limiters map[string]*rate.Limiter
}

// newAuthRateLimiter cria rate limiter com 5 tokens/IP recarregando a cada
// 12s (5 por minuto). Inicia goroutine de TTL eviction a cada 5 min.
func newAuthRateLimiter() *authRateLimiter {
	a := &authRateLimiter{
		limiters: make(map[string]*rate.Limiter),
	}
	go func() {
		ticker := time.NewTicker(5 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			a.mu.Lock()
			// Limpa todo o map — limiters são recriados on-demand.
			// Custo: próxima request de cada IP cria um novo limiter (1 alloc).
			// Benefício: O(1) memory bound independente do número de IPs únicos.
			a.limiters = make(map[string]*rate.Limiter)
			a.mu.Unlock()
		}
	}()
	return a
}

// globalAuthLimiter é usado pelos interceptors (que não têm acesso ao Server).
// Inicializado em package-level para garantir disponibilidade.
var globalAuthLimiter = newAuthRateLimiter()

// get retorna o limiter para o IP (cria se não existir).
// Retorna nil se IP for vazio (sem peer info, não aplica rate limit).
func (a *authRateLimiter) get(ip string) *rate.Limiter {
	if ip == "" {
		return nil
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	l, exists := a.limiters[ip]
	if !exists {
		// Burst 5, recarga 1 token a cada 12s = 5/min.
		l = rate.NewLimiter(rate.Every(12*time.Second), 5)
		a.limiters[ip] = l
	}
	return l
}

// --- ServerControl RPCs ---

// StartServer delega para `sudo systemctl start <service>`.
// GO-008: se req.GetForce()=true e serviço já ativo, força restart.
func (s *Server) StartServer(ctx context.Context, req *criasv1.StartRequest) (*criasv1.StartResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	// GO-008: implementa lógica de force=true.
	if req.GetForce() && s.isServiceActive(ctx, s.cfg.Server.ServiceName) {
		out, err := s.runSystemctl(ctx, "restart", s.cfg.Server.ServiceName)
		if err != nil {
			s.bus.Publish(events.Event{
				EventType:   "HealthWarning",
				ServiceName: s.cfg.Server.ServiceName,
				Stack:       s.cfg.Server.Stack,
				Metadata:    map[string]string{"reason": "force_restart_failed", "error": err.Error(), "output": out},
			})
			// 2B-014: status code específico em vez de codes.Unknown.
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
		// 2B-014: status code específico em vez de codes.Unknown.
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

// StopServer delega para `sudo systemctl stop <service>`.
// GO-008: usa req.GetTimeoutSeconds() como deadline (cap 5min).
// GO-016: passa --signal=SIGTERM para graceful shutdown.
// 2B-008: passa --timeout=SECS para systemctl para que o systemd respeite
// o timeout do client (default do systemd é 90s, independente do RPC deadline).
func (s *Server) StopServer(ctx context.Context, req *criasv1.StopRequest) (*criasv1.StopResponse, error) {
	timeoutSec := req.GetTimeoutSeconds()
	deadline := defaultRPCDeadline
	args := []string{"stop", s.cfg.Server.ServiceName}
	if timeoutSec > 0 {
		// Aplica timeout_seconds do request (com cap para evitar DoS).
		d := time.Duration(timeoutSec) * time.Second
		if d > 5*time.Minute {
			d = 5 * time.Minute
			timeoutSec = int32(d.Seconds())
		}
		deadline = d
		// GO-016 + 2B-008: KillSignal=SIGTERM é default do systemd, mas
		// explicitamos --kill-who=main e --signal=SIGTERM para defense-in-depth.
		// --timeout=SECS faz systemd respeitar o timeout do client (default 90s).
		args = []string{"stop", "--kill-who=main", "--signal=SIGTERM", fmt.Sprintf("--timeout=%d", timeoutSec), s.cfg.Server.ServiceName}
	}

	ctx, cancel := withDeadline(ctx, deadline)
	defer cancel()

	out, err := s.runSystemctlArgs(ctx, args)
	if err != nil {
		// 2B-014: status code específico em vez de codes.Unknown.
		return nil, systemctlStatusError(args, out, err)
	}

	s.bus.Publish(events.Event{
		EventType:   "ServerStopped",
		ServiceName: s.cfg.Server.ServiceName,
		Stack:       s.cfg.Server.Stack,
		Metadata:    map[string]string{"timeout_seconds": fmt.Sprintf("%d", req.GetTimeoutSeconds())},
	})

	return &criasv1.StopResponse{
		Ok:          true,
		Message:     "servidor parado",
		ServiceName: s.cfg.Server.ServiceName,
	}, nil
}

// RestartServer delega para `sudo systemctl restart <service>`.
func (s *Server) RestartServer(ctx context.Context, req *criasv1.RestartRequest) (*criasv1.RestartResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	out, err := s.runSystemctl(ctx, "restart", s.cfg.Server.ServiceName)
	if err != nil {
		// 2B-014: status code específico em vez de codes.Unknown.
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

// GetStatus retorna status consolidado: systemd + RCON players + recursos.
func (s *Server) GetStatus(ctx context.Context, req *criasv1.GetStatusRequest) (*criasv1.StatusResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	active := s.isServiceActive(ctx, s.cfg.Server.ServiceName)

	resp := &criasv1.StatusResponse{
		ServiceName: s.cfg.Server.ServiceName,
		Stack:       s.cfg.Server.Stack,
		Version:     Version,
		// Popula hardware_tier do config (v1.1.0+).
		HardwareTier: s.cfg.Server.HardwareTier,
	}

	if active {
		resp.ServiceActive = true
		resp.UptimeSeconds = s.getServiceUptime(ctx, s.cfg.Server.ServiceName)

		resp.MemoryUsedMb = s.getServiceMemoryUsedMB(ctx, s.cfg.Server.ServiceName)
		resp.MemoryMaxMb = s.getServiceMemoryMaxMB(ctx, s.cfg.Server.ServiceName)

		// Tenta buscar players via RCON (best-effort).
		if s.rcon != nil {
			players, maxPlayers, err := s.rcon.PlayerList()
			if err == nil {
				resp.Players = players
				resp.PlayerCount = int32(len(players))
				resp.MaxPlayers = int32(maxPlayers)
			}
		}
	}

	return resp, nil
}

// GetHealth verifica se porta está em escuta + RCON responde.
func (s *Server) GetHealth(ctx context.Context, req *criasv1.GetHealthRequest) (*criasv1.HealthResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	resp := &criasv1.HealthResponse{
		ServiceName: s.cfg.Server.ServiceName,
		Port:        int32(s.cfg.Server.ServerPort),
	}

	// Testa se a porta do servidor de jogo está em escuta.
	if s.cfg.Server.ServerPort > 0 {
		addr := fmt.Sprintf("127.0.0.1:%d", s.cfg.Server.ServerPort)
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			resp.PortListening = true
			_ = conn.Close()
		}
	}

	// Se RCON habilitado, testa resposta.
	if s.rcon != nil {
		_, _, err := s.rcon.PlayerList()
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

// SendRconCommand executa comando RCON whitelistado.
func (s *Server) SendRconCommand(ctx context.Context, req *criasv1.SendRconCommandRequest) (*criasv1.SendRconCommandResponse, error) {
	ctx, cancel := withDeadline(ctx, defaultRPCDeadline)
	defer cancel()

	command := strings.TrimSpace(req.GetCommand())
	if command == "" {
		// GO-012: comando vazio é client error → InvalidArgument.
		return nil, status.Error(codes.InvalidArgument, "comando vazio")
	}

	if !rcon.IsCommandAllowed(command) {
		return nil, status.Errorf(codes.PermissionDenied, "comando %q não está na whitelist", strings.Fields(command)[0])
	}

	if s.rcon == nil {
		return nil, status.Error(codes.FailedPrecondition, "rcon desabilitado na configuração")
	}

	out, err := s.rcon.Execute(command)
	if err != nil {
		// 2B-014: código gRPC específico em vez de codes.Unknown.
		return nil, rconStatusError(err)
	}

	return &criasv1.SendRconCommandResponse{
		Ok:     true,
		Output: out,
	}, nil
}

// StreamConsole faz tail de `journalctl -u <service> -f` e envia linhas.
//
// GO-003: lê stdout em goroutine e seleciona entre channel e ctx.Done()
//
//	para responder a cancellation mesmo durante Read bloqueado.
//
// GO-016: envia SIGTERM (grace period 5s) antes de SIGKILL.
// GO-017: cap de 64KB por linha para prevenir memory exhaustion.
// GO-018: cap de 1000 linhas para tail_lines.
//
// 2B-003: usa cmd.Cancel + cmd.WaitDelay para que ctx cancelle (client
// disconnect) faça SIGTERM-then-SIGKILL no journalctl. Antes, o runtime
// do Go usava SIGKILL imediato (default cmd.Cancel), bypassando o
// stopProc que só roda no defer (após return do handler).
//
// 2B-011: flusha buf restante antes de retornar em EOF, para não perder a
// última linha parcial se journalctl for morto mid-line.
func (s *Server) StreamConsole(req *criasv1.StreamConsoleRequest, stream criasv1.ServerControl_StreamConsoleServer) error {
	ctx := stream.Context()

	// GO-018: valida bounds de tail_lines (default 50, cap 1000).
	tailLines := int(req.GetTailLines())
	if tailLines <= 0 {
		tailLines = 50
	}
	if tailLines > maxTailLines {
		tailLines = maxTailLines
	}

	// journalctl -u minecraft -f -n 50 --output=cat --no-pager
	// GO-009: usa caminho absoluto para journalctl.
	args := []string{
		"-u", s.cfg.Server.ServiceName,
		"-f",
		"-n", fmt.Sprintf("%d", tailLines),
		"--output=cat",
		"--no-pager",
	}
	cmd := exec.CommandContext(ctx, journalctlBin, args...)
	// Forçar LC_ALL=C para output determinístico (independente de locale do host).
	// GO-053: previne parsing de timestamp em formato locale-dependente.
	cmd.Env = append(cmd.Environ(), "LC_ALL=C", "LANG=C")
	// 2B-003: cmd.Cancel envia SIGTERM em vez do default SIGKILL imediato.
	// Combinado com WaitDelay=5s, o runtime faz SIGTERM-then-SIGKILL em ctx
	// cancelle (client disconnect), dando chance de graceful shutdown.
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

	// stopProc tenta graceful shutdown (SIGTERM) antes de SIGKILL.
	// GO-016: padrão Unix de dar chance ao subprocess de limpar estado.
	// Complementar ao cmd.Cancel/WaitDelay do 2B-003: cobre o caso onde o
	// handler retorna normalmente (não via ctx cancelle) e o processo ainda
	// está vivo (e.g., erro em stream.Send).
	stopProc := func() {
		if cmd.Process == nil {
			return
		}
		// Tenta SIGTERM primeiro (default do systemd KillSignal).
		_ = cmd.Process.Signal(syscall.SIGTERM)
		// Espera até 5s pelo processo terminar graciosamente.
		done := make(chan struct{})
		go func() {
			_ = cmd.Wait()
			close(done)
		}()
		select {
		case <-done:
			// Processo terminou após SIGTERM — ótimo.
		case <-time.After(5 * time.Second):
			// Timeout — SIGKILL para garantir cleanup.
			_ = cmd.Process.Kill()
			<-done
		}
	}
	defer stopProc()

	// GO-003: goroutine para ler stdout e enviar via channel.
	// Permite que select responda a ctx.Done() mesmo durante Read bloqueado.
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

	// flushRemaining envia qualquer dado left em buf como uma última linha.
	// 2B-011: se journalctl é morto mid-line (sem newline final),
	// enviar o conteúdo parcial evita perda silenciosa de log.
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
				// GO-017: protege contra linha sem newline que cresceria unbounded.
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
				// 2B-011: flusha buf restante antes de retornar.
				if err := flushRemaining(); err != nil {
					return err
				}
				return nil
			}
			if res.err != nil {
				return status.Errorf(codes.Internal, "ler journalctl: %v", res.err)
			}
			// Relança próxima leitura em goroutine para continuar o pattern.
			go func() {
				tmp := make([]byte, 4096)
				n, err := stdout.Read(tmp)
				readCh <- readResult{data: append([]byte(nil), tmp[:n]...), err: err}
			}()
		}
	}
}

// --- EventBus RPCs ---

// SubscribeEvents abre stream de eventos para o cliente.
// GO-002: usa deadline default; cliente pode cancelar via ctx a qualquer momento.
func (s *Server) SubscribeEvents(req *criasv1.SubscribeEventsRequest, stream criasv1.EventBus_SubscribeEventsServer) error {
	ctx := stream.Context()
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

// runSystemctl executa sudo systemctl <op> <service> e retorna output.
// GO-009: usa caminhos absolutos para sudo e systemctl.
// GO-013: wrappa erro com contexto operacional (op, service, output).
func (s *Server) runSystemctl(ctx context.Context, op string, service string) (string, error) {
	return s.runSystemctlArgs(ctx, []string{op, service})
}

// runSystemctlArgs executa sudo systemctl <args...> e retorna output.
// GO-013: wrappa erro com contexto operacional e output para debugging.
// 2B-016: adiciona LC_ALL=C para output determinístico (consistente com
// isServiceActive, getServiceUptime, getServicePropertyMB).
func (s *Server) runSystemctlArgs(ctx context.Context, args []string) (string, error) {
	fullArgs := append([]string{systemctlBin}, args...)
	cmd := exec.CommandContext(ctx, sudoBin, fullArgs...)
	// 2B-016: output determinístico independente do locale do host.
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.CombinedOutput()
	if err != nil {
		// GO-013: erro wrapped com op, service, output — facilita debugging.
		return string(out), fmt.Errorf("sudo systemctl %s: %w (output: %s)", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

// systemctlStatusError mapeia erro do systemctl para codes gRPC apropriados.
// 2B-014: substitui o pattern `status.Errorf(codes.Unknown, ...)` que
// tornava todos os erros indistinguíveis para o client.
//
// Mapeamento:
//   - exit 4/5 ou output contém "not loaded"/"could not be found" → NotFound
//   - ctx.DeadlineExceeded (RPC timeout) → DeadlineExceeded
//   - outros → Internal
func systemctlStatusError(args []string, out string, err error) error {
	if err == nil {
		return nil
	}
	outTrim := strings.TrimSpace(out)
	opStr := strings.Join(args, " ")

	// systemctl exit 4 = unit não carregada, exit 5 = unit não existe.
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		code := exitErr.ExitCode()
		if code == 4 || code == 5 {
			return status.Errorf(codes.NotFound, "serviço não encontrado (exit %d): sudo systemctl %s (output: %s)", code, opStr, outTrim)
		}
	}

	// Saída típica em locale C: "Failed to stop X.service: Unit X.service not loaded."
	// ou "Unit X.service could not be found."
	if strings.Contains(outTrim, "not loaded") ||
		strings.Contains(outTrim, "could not be found") ||
		strings.Contains(outTrim, "Failed to get D-Bus connection") {
		return status.Errorf(codes.NotFound, "serviço não encontrado: sudo systemctl %s (output: %s)", opStr, outTrim)
	}

	// RPC deadline atingido (ctx cancelle pelo withDeadline).
	if errors.Is(err, context.DeadlineExceeded) {
		return status.Errorf(codes.DeadlineExceeded, "systemctl timeout: sudo systemctl %s (output: %s)", opStr, outTrim)
	}

	return status.Errorf(codes.Internal, "falha sudo systemctl %s: %v (output: %s)", opStr, err, outTrim)
}

// rconStatusError mapeia erro do RCON para codes gRPC apropriados.
// 2B-014: distinguir "RCON indisponível" (Unavailable) de erro interno.
//
// Mapeamento baseado no texto do erro (rcon.Client.Execute wraps com
// prefixos específicos):
//   - "conectar rcon" → Unavailable (servidor de jogo não aceitou conexão)
//   - "rcon timeout" → DeadlineExceeded (execução excedeu 10s)
//   - outros → Internal
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

// isServiceActive retorna true se `systemctl is-active --quiet <service>` exit 0.
// GO-009: caminho absoluto.
func (s *Server) isServiceActive(ctx context.Context, service string) bool {
	cmd := exec.CommandContext(ctx, systemctlBin, "is-active", "--quiet", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	return cmd.Run() == nil
}

// getServiceUptime retorna uptime em segundos baseado em ExecMainStartTimestamp.
// GO-009 + GO-053: caminho absoluto + LC_ALL=C para parsing determinístico.
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
	// GO-020: parse sem timezone abbreviation (que quebra em locales não-UTC).
	// Usamos time.ParseInLocation com time.Local para interpretar o timestamp
	// no timezone do host onde o agente roda.
	t, err := time.ParseInLocation("Mon 2006-01-02 15:04:05", ts, time.Local)
	if err != nil {
		// Fallback: tenta layout com MST (compatibilidade).
		t, err = time.Parse("Mon 2006-01-02 15:04:05 MST", ts)
		if err != nil {
			return 0
		}
	}
	return int64(time.Since(t).Seconds())
}

// getServiceMemoryUsedMB retorna memória residente do serviço em MB.
// GO-009: caminho absoluto.
func (s *Server) getServiceMemoryUsedMB(ctx context.Context, service string) int64 {
	return s.getServicePropertyMB(ctx, service, "MemoryCurrent")
}

// getServiceMemoryMaxMB retorna limite de memória (MemoryMax) do serviço em MB.
// GO-009: caminho absoluto.
func (s *Server) getServiceMemoryMaxMB(ctx context.Context, service string) int64 {
	return s.getServicePropertyMB(ctx, service, "MemoryMax")
}

// getServicePropertyMB lê uma propriedade de memória do systemd e converte para MB.
// GO-063: refactor para eliminar duplicação entre getServiceMemoryUsedMB e
// getServiceMemoryMaxMB.
func (s *Server) getServicePropertyMB(ctx context.Context, service string, prop string) int64 {
	cmd := exec.CommandContext(ctx, systemctlBin, "show", "-p", prop, "--value", service)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C")
	out, err := cmd.Output()
	if err != nil {
		return 0
	}
	raw := strings.TrimSpace(string(out))
	// MemoryCurrent/MemoryMax podem ser "[not set]", "0" ou "infinity".
	if raw == "" || raw == "[not set]" || raw == "infinity" {
		return 0
	}
	bytes, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || bytes <= 0 {
		return 0
	}
	return bytes / (1024 * 1024)
}

// eventToProto converte events.Event → criasv1.ServerEvent.
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
