// Package server tests.
//
// Estes testes cobrem as funções puras e a lógica de validação de server.go
// (TST-003). Os RPCs que dependem de `systemctl`/`journalctl` (StartServer,
// StopServer, RestartServer, GetStatus, GetHealth, StreamConsole) não são
// testados diretamente porque exigem sudo + systemd — fora do escopo de testes
// unitários. Em vez disso, testamos:
//   - validateToken: validação do token x-api-token (constante-time compare).
//   - AuthInterceptor / StreamAuthInterceptor: fluxo de auth gRPC.
//   - eventToProto: conversão events.Event → criasv1.ServerEvent.
//   - SendRconCommand: validação de input (comando vazio, não-whitelistado,
//     rcon desabilitado) — paths que não tocam a rede.
//
// Padrão: table-driven tests (https://go.dev/blog/subtests).
package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/time/rate"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"

	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/config"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
	criasv1 "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/proto"
)

// --- validateToken ---
//
// validateToken tem assinatura (ctx, expected, ip) — ip é usado apenas para
// log de audit trail, não afeta a lógica de validação. Passamos "" em todos
// os testes para não acionar rate limiting (que é testado separadamente).

func TestValidateToken(t *testing.T) {
	const expected = "5f4f4e2c3a1b0a8e7d6c5b4a39383736353433413231302f2e2d2c2b2a2928" // 64 hex chars

	tests := []struct {
		name     string
		ctx      context.Context
		wantCode codes.Code
		wantMsg  string
	}{
		{
			name:     "valid token",
			ctx:      metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", expected)),
			wantCode: codes.OK,
		},
		{
			name:     "invalid token (same length)",
			ctx:      metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")),
			wantCode: codes.Unauthenticated,
			wantMsg:  "token inválido",
		},
		{
			name:     "empty token value",
			ctx:      metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", "")),
			wantCode: codes.Unauthenticated,
			wantMsg:  "token inválido",
		},
		{
			name:     "missing x-api-token metadata key",
			ctx:      metadata.NewIncomingContext(context.Background(), metadata.Pairs("other-key", "value")),
			wantCode: codes.Unauthenticated,
			wantMsg:  "x-api-token metadata ausente",
		},
		{
			name:     "context without metadata at all",
			ctx:      context.Background(),
			wantCode: codes.Unauthenticated,
			wantMsg:  "metadata ausente",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateToken(tt.ctx, expected, "")
			if tt.wantCode == codes.OK {
				if err != nil {
					t.Fatalf("esperado nil error, obtido %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("esperado erro com código %s, obtido nil", tt.wantCode)
			}
			st, ok := status.FromError(err)
			if !ok {
				t.Fatalf("erro não é grpc status: %T %v", err, err)
			}
			if st.Code() != tt.wantCode {
				t.Errorf("code = %s, esperado %s (msg: %s)", st.Code(), tt.wantCode, st.Message())
			}
			if tt.wantMsg != "" && st.Message() != tt.wantMsg {
				t.Errorf("message = %q, esperado %q", st.Message(), tt.wantMsg)
			}
		})
	}
}

// TestValidateToken_DifferentLengths garante que subtle.ConstantTimeCompare
// não panica e retorna erro para tokens de comprimentos diferentes.
func TestValidateToken_DifferentLengths(t *testing.T) {
	const expected = "abcdef123456"
	tests := []struct {
		name  string
		token string
	}{
		{"shorter", "abc"},
		{"longer", "abcdef12345678901234567890"},
		{"empty", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", tt.token))
			err := validateToken(ctx, expected, "")
			if err == nil {
				t.Fatal("esperado erro para token de comprimento diferente")
			}
			st, _ := status.FromError(err)
			if st.Code() != codes.Unauthenticated {
				t.Errorf("code = %s, esperado Unauthenticated", st.Code())
			}
		})
	}
}

// --- AuthInterceptor ---
//
// Os interceptors chamam checkAuth, que por sua vez chama validateToken.
// Sem peer info no ctx, o rate limiter é pulado — não atrapalha os testes.

func TestAuthInterceptor_ValidToken(t *testing.T) {
	const token = "valid-token-123"
	interceptor := AuthInterceptor(token)

	handlerCalled := false
	handler := func(ctx context.Context, req any) (any, error) {
		handlerCalled = true
		if req != "request-payload" {
			t.Errorf("req mutado: %v", req)
		}
		return "response", nil
	}

	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", token))
	info := &grpc.UnaryServerInfo{FullMethod: "/crias.v1.ServerControl/StartServer"}

	resp, err := interceptor(ctx, "request-payload", info, handler)
	if err != nil {
		t.Fatalf("esperado nil error, obtido %v", err)
	}
	if resp != "response" {
		t.Errorf("resp = %v, esperado response", resp)
	}
	if !handlerCalled {
		t.Error("handler não foi chamado")
	}
}

func TestAuthInterceptor_InvalidToken_BlockHandler(t *testing.T) {
	const token = "valid-token-123"
	interceptor := AuthInterceptor(token)

	handlerCalled := false
	handler := func(ctx context.Context, req any) (any, error) {
		handlerCalled = true
		return nil, nil
	}

	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", "wrong"))
	info := &grpc.UnaryServerInfo{FullMethod: "/crias.v1.ServerControl/StartServer"}

	resp, err := interceptor(ctx, nil, info, handler)
	if err == nil {
		t.Fatal("esperado erro, obtido nil")
	}
	if resp != nil {
		t.Errorf("resp deve ser nil quando auth falha, obtido %v", resp)
	}
	if handlerCalled {
		t.Error("handler não deve ser chamado quando auth falha")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.Unauthenticated {
		t.Errorf("code = %s, esperado Unauthenticated", st.Code())
	}
}

func TestAuthInterceptor_MissingMetadata(t *testing.T) {
	interceptor := AuthInterceptor("any")

	handler := func(ctx context.Context, req any) (any, error) {
		t.Error("handler não deve ser chamado sem metadata")
		return nil, nil
	}

	info := &grpc.UnaryServerInfo{FullMethod: "/x/y"}
	_, err := interceptor(context.Background(), nil, info, handler)
	if err == nil {
		t.Fatal("esperado erro sem metadata")
	}
}

// --- StreamAuthInterceptor ---

// fakeServerStream implementa grpc.ServerStream apenas para carregar o context.
type fakeServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (f *fakeServerStream) Context() context.Context { return f.ctx }

func TestStreamAuthInterceptor_ValidToken(t *testing.T) {
	const token = "valid"
	interceptor := StreamAuthInterceptor(token)

	handlerCalled := false
	handler := func(srv any, ss grpc.ServerStream) error {
		handlerCalled = true
		return nil
	}

	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", token))
	ss := &fakeServerStream{ctx: ctx}
	info := &grpc.StreamServerInfo{FullMethod: "/crias.v1.EventBus/SubscribeEvents"}

	if err := interceptor(nil, ss, info, handler); err != nil {
		t.Fatalf("esperado nil error, obtido %v", err)
	}
	if !handlerCalled {
		t.Error("handler não foi chamado")
	}
}

func TestStreamAuthInterceptor_InvalidToken(t *testing.T) {
	const token = "valid"
	interceptor := StreamAuthInterceptor(token)

	handler := func(srv any, ss grpc.ServerStream) error {
		t.Error("handler não deve ser chamado")
		return nil
	}

	ctx := metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", "invalid"))
	ss := &fakeServerStream{ctx: ctx}
	info := &grpc.StreamServerInfo{FullMethod: "/crias.v1.EventBus/SubscribeEvents"}

	err := interceptor(nil, ss, info, handler)
	if err == nil {
		t.Fatal("esperado erro, obtido nil")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.Unauthenticated {
		t.Errorf("code = %s, esperado Unauthenticated", st.Code())
	}
}

// --- eventToProto ---

func TestEventToProto(t *testing.T) {
	tests := []struct {
		name string
		ev   events.Event
		want func(*criasv1.ServerEvent) bool
	}{
		{
			name: "full event",
			ev: events.Event{
				EventID:       "evt-123",
				EventType:     "PlayerJoined",
				TimestampUnix: 1700000000,
				ServiceName:   "minecraft",
				Stack:         "minecraft",
				Metadata:      map[string]string{"player": "Steve"},
			},
			want: func(p *criasv1.ServerEvent) bool {
				return p.EventId == "evt-123" &&
					p.EventType == "PlayerJoined" &&
					p.TimestampUnix == 1700000000 &&
					p.ServiceName == "minecraft" &&
					p.Stack == "minecraft" &&
					p.Metadata["player"] == "Steve"
			},
		},
		{
			name: "empty event",
			ev:   events.Event{},
			want: func(p *criasv1.ServerEvent) bool {
				return p.EventId == "" && p.EventType == "" && p.Metadata == nil
			},
		},
		{
			name: "nil metadata",
			ev: events.Event{
				EventType:   "ServerStarted",
				ServiceName: "terraria",
				Metadata:    nil,
			},
			want: func(p *criasv1.ServerEvent) bool {
				return p.Metadata == nil && p.ServiceName == "terraria"
			},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := eventToProto(tt.ev)
			if got == nil {
				t.Fatal("eventToProto retornou nil")
			}
			if !tt.want(got) {
				t.Errorf("eventToProto(%+v) = %+v — campos não batem", tt.ev, got)
			}
		})
	}
}

// --- SendRconCommand input validation ---
//
// Estes testes exercitam os caminhos de validação de input de SendRconCommand
// que não tocam rede/systemctl: comando vazio, comando não-whitelistado e
// rcon desabilitado. Os caminhos que chamam rcon.Execute são cobertos por
// client_test.go (com mock de dialer).
//
// These paths return gRPC status errors with appropriate codes.

// newTestServer cria um Server mínimo para testes. rcon=nil desabilita RCON.
func newTestServer(rconEnabled bool) *Server {
	cfg := &config.Config{
		Agent: config.AgentConfig{AuthToken: "test"},
		Server: config.ServerConfig{
			Stack:       "minecraft",
			ServiceName: "minecraft",
			ServerPort:  25565,
			RCON: config.RCONConfig{
				Enabled: rconEnabled,
				Host:    "127.0.0.1",
				Port:    25575,
			},
		},
	}
	return New(cfg, nil, events.NewBus(), "test-version")
}

func TestSendRconCommand_EmptyCommand(t *testing.T) {
	s := newTestServer(true)
	_, err := s.SendRconCommand(context.Background(), &criasv1.SendRconCommandRequest{Command: "   "})
	if err == nil {
		t.Fatal("esperado erro para comando vazio")
	}
	st, ok := status.FromError(err)
	if !ok {
		t.Fatalf("erro não é grpc status: %v", err)
	}
	if st.Code() != codes.InvalidArgument {
		t.Errorf("code = %s, esperado InvalidArgument", st.Code())
	}
	if st.Message() != "comando vazio" {
		t.Errorf("message = %q, esperado 'comando vazio'", st.Message())
	}
}

func TestSendRconCommand_NotWhitelisted(t *testing.T) {
	s := newTestServer(true)
	// "stop" está fora da whitelist (perigo: desliga o servidor).
	_, err := s.SendRconCommand(context.Background(), &criasv1.SendRconCommandRequest{Command: "stop"})
	if err == nil {
		t.Fatal("esperado erro para comando não-whitelistado")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.PermissionDenied {
		t.Errorf("code = %s, esperado PermissionDenied", st.Code())
	}
}

func TestSendRconCommand_RCONDisabled(t *testing.T) {
	// Mesmo com comando whitelistado, se rcon=nil (desabilitado), deve
	// retornar FailedPrecondition.
	s := newTestServer(false)
	_, err := s.SendRconCommand(context.Background(), &criasv1.SendRconCommandRequest{Command: "list"})
	if err == nil {
		t.Fatal("esperado erro quando rcon desabilitado")
	}
	st, _ := status.FromError(err)
	if st.Code() != codes.FailedPrecondition {
		t.Errorf("code = %s, esperado FailedPrecondition", st.Code())
	}
}

// --- New() constructor ---

func TestNew_InitializesState(t *testing.T) {
	s := newTestServer(true)
	if s.knownPlayers == nil {
		t.Error("knownPlayers não deve ser nil após New()")
	}
	if len(s.knownPlayers) != 0 {
		t.Errorf("knownPlayers deve estar vazio, obtido %d entradas", len(s.knownPlayers))
	}
	if s.cfg == nil {
		t.Error("cfg não deve ser nil")
	}
	if s.bus == nil {
		t.Error("bus não deve ser nil")
	}
	// Auth rate limiting is handled by the package-level globalAuthLimiter.
	if globalAuthLimiter == nil {
		t.Error("globalAuthLimiter não deve ser nil (package-level init)")
	}
}

// TestNew_SetsVersion garante que New() com version não-vazia sobrescreve
// a variável package-level Version.
func TestNew_SetsVersion(t *testing.T) {
	original := Version
	defer func() { Version = original }()

	_ = New(&config.Config{Agent: config.AgentConfig{AuthToken: "x"}, Server: config.ServerConfig{ServiceName: "mc"}}, nil, events.NewBus(), "v1.2.3-test")
	if Version != "v1.2.3-test" {
		t.Errorf("Version = %q, esperado 'v1.2.3-test'", Version)
	}
}

func TestNew_EmptyVersionKeepsDefault(t *testing.T) {
	original := Version
	defer func() { Version = original }()
	Version = "dev"

	_ = New(&config.Config{Agent: config.AgentConfig{AuthToken: "x"}, Server: config.ServerConfig{ServiceName: "mc"}}, nil, events.NewBus(), "")
	if Version != "dev" {
		t.Errorf("Version = %q, esperado 'dev' (default)", Version)
	}
}

// --- authRateLimiter ---

func TestAuthRateLimiter_EmptyIPReturnsNil(t *testing.T) {
	limiter := newAuthRateLimiter(5, rate.Every(12*time.Second))
	l, err := limiter.get("")
	if l != nil || err != nil {
		t.Errorf("esperado (nil, nil) para IP vazio, obtido (%v, %v)", l, err)
	}
}

func TestAuthRateLimiter_CreatesLimiterForNewIP(t *testing.T) {
	limiter := newAuthRateLimiter(5, rate.Every(12*time.Second))
	l1, err := limiter.get("1.2.3.4")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if l1 == nil {
		t.Fatal("esperado limiter não-nil para IP válido")
	}
	// Segunda chamada com mesmo IP deve retornar o mesmo limiter.
	l2, _ := limiter.get("1.2.3.4")
	if l1 != l2 {
		t.Error("esperado mesma instância de limiter para o mesmo IP")
	}
}

// TestAuthRateLimiter_MapCap (EXP-46): o mapa de limiters tem cap duro; quando
// cheio de entradas recentes, get falha com errLimiterMapFull; entradas idle
// além do TTL são evitadas para abrir espaço.
func TestAuthRateLimiter_MapCap(t *testing.T) {
	limiter := newAuthRateLimiter(5, rate.Every(12*time.Second))
	limiter.cap = 3

	for _, ip := range []string{"10.0.0.1", "10.0.0.2", "10.0.0.3"} {
		if _, err := limiter.get(ip); err != nil {
			t.Fatalf("get(%s): %v", ip, err)
		}
	}

	// Mapa cheio de entradas recentes → 4º IP distinto é rejeitado (fail closed).
	if _, err := limiter.get("10.0.0.4"); !errors.Is(err, errLimiterMapFull) {
		t.Fatalf("esperado errLimiterMapFull com mapa cheio, obtido %v", err)
	}

	// Backdate das entradas para além do TTL idle → são evitadas e o novo IP passa.
	limiter.mu.Lock()
	idle := time.Now().Add(-2 * limiterIdleTTL)
	for _, e := range limiter.limiters {
		e.lastUsed = idle
	}
	limiter.mu.Unlock()

	if _, err := limiter.get("10.0.0.4"); err != nil {
		t.Fatalf("esperado sucesso após evicção de entradas idle, obtido %v", err)
	}
	limiter.mu.Lock()
	remaining := len(limiter.limiters)
	limiter.mu.Unlock()
	if remaining != 1 {
		t.Errorf("após evicção + 1 inserção, esperado 1 entrada, obtido %d", remaining)
	}

	// O cap default do limiter global é limiterMapCap.
	if limiterMapCap != 10000 {
		t.Errorf("limiterMapCap = %d, esperado 10000", limiterMapCap)
	}
	if globalAuthLimiter.cap != limiterMapCap || globalAuthedLimiter.cap != limiterMapCap {
		t.Error("limiters globais devem usar o cap default")
	}
}

// peerRPC devolve um ctx de teste com metadata x-api-token=<token> e peer IP
// <ip> — sem o peer, clientIP() retorna "" e o rate limiting é pulado.
func peerRPC(token, ip string) context.Context {
	return peer.NewContext(
		metadata.NewIncomingContext(context.Background(), metadata.Pairs("x-api-token", token)),
		&peer.Peer{Addr: &net.TCPAddr{IP: net.ParseIP(ip), Port: 54321}},
	)
}

// withFreshLimiters troca os limiters globais por instâncias frescas para o
// teste corrente e restaura os originais no cleanup. Os limiters são
// package-level e os buckets não zeram entre execuções — sem isso, rodar os
// testes mais de uma vez no mesmo processo (go test -count>1) falha porque o
// run seguinte herda os tokens esgotados do anterior.
func withFreshLimiters(t *testing.T) {
	t.Helper()
	origBad, origAuthed := globalAuthLimiter, globalAuthedLimiter
	globalAuthLimiter = newAuthRateLimiter(5, rate.Every(12*time.Second))
	globalAuthedLimiter = newAuthRateLimiter(60, 30)
	t.Cleanup(func() {
		globalAuthLimiter = origBad
		globalAuthedLimiter = origAuthed
	})
}

// --- checkAuth: ordem token → rate limit (EXP-46) ---

// TestCheckAuth_AuthenticatedBurstNotThrottled (EXP-46): 15 RPCs SEQUENCIAIS
// com token VÁLIDO e mesmo IP devem passar todos — antes do fix, o limiter
// agressivo (burst 5, 1/12s) aplicava a TODAS as chamadas e o 6º request
// legítimo tomava ResourceExhausted.
func TestCheckAuth_AuthenticatedBurstNotThrottled(t *testing.T) {
	withFreshLimiters(t)
	const token = "valid-token-123"
	interceptor := AuthInterceptor(token)
	info := &grpc.UnaryServerInfo{FullMethod: "/crias.v1.ServerControl/GetStatus"}

	// IP único para não interferir com outros testes (limiters são globais).
	const ip = "192.0.2.11"

	handlerCalls := 0
	handler := func(ctx context.Context, req any) (any, error) {
		handlerCalls++
		return "ok", nil
	}

	for i := 0; i < 15; i++ {
		resp, err := interceptor(peerRPC(token, ip), "req", info, handler)
		if err != nil {
			t.Fatalf("RPC autenticado #%d falhou: %v (EXP-46: tráfego legítimo não deve ser throttled)", i+1, err)
		}
		if resp != "ok" {
			t.Fatalf("resp inesperado: %v", resp)
		}
	}
	if handlerCalls != 15 {
		t.Errorf("handler chamado %d vezes, esperado 15", handlerCalls)
	}
}

// TestCheckAuth_InvalidTokenBurstLimited (EXP-46): rajada de requests com
// token INVÁLIDO do mesmo IP — os 5 primeiros tomam Unauthenticated, os
// seguintes ResourceExhausted (proteção brute-force mantida).
func TestCheckAuth_InvalidTokenBurstLimited(t *testing.T) {
	withFreshLimiters(t)
	const token = "valid-token-123"
	interceptor := AuthInterceptor(token)
	info := &grpc.UnaryServerInfo{FullMethod: "/crias.v1.ServerControl/GetStatus"}

	const ip = "192.0.2.22"

	handler := func(ctx context.Context, req any) (any, error) {
		t.Error("handler não deve ser chamado com token inválido")
		return nil, nil
	}

	unauthenticated := 0
	resourceExhausted := 0
	for i := 0; i < 8; i++ {
		_, err := interceptor(peerRPC("wrong-token", ip), nil, info, handler)
		if err == nil {
			t.Fatalf("request #%d com token inválido não deveria passar", i+1)
		}
		switch status.Code(err) {
		case codes.Unauthenticated:
			unauthenticated++
		case codes.ResourceExhausted:
			resourceExhausted++
		default:
			t.Fatalf("request #%d: code inesperado %s (%v)", i+1, status.Code(err), err)
		}
	}
	// Burst 5: os 5 primeiros consomem os tokens (Unauthenticated), o resto é
	// cortado pelo limiter (ResourceExhausted).
	if unauthenticated != 5 {
		t.Errorf("esperado 5 Unauthenticated (burst), obtido %d", unauthenticated)
	}
	if resourceExhausted != 3 {
		t.Errorf("esperado 3 ResourceExhausted (pós-burst), obtido %d", resourceExhausted)
	}
}

// TestCheckAuth_ValidTokenWorksWithExhaustedBadAuthBucket (EXP-46): com o
// bucket agressivo do IP esgotado por tentativas inválidas, um request com
// token VÁLIDO do MESMO IP deve passar (limiters são independentes).
func TestCheckAuth_ValidTokenWorksWithExhaustedBadAuthBucket(t *testing.T) {
	withFreshLimiters(t)
	const token = "valid-token-123"
	interceptor := AuthInterceptor(token)
	info := &grpc.UnaryServerInfo{FullMethod: "/crias.v1.ServerControl/GetStatus"}

	const ip = "192.0.2.33"

	// Esgota o bucket agressivo com tokens inválidos.
	for i := 0; i < 6; i++ {
		_, _ = interceptor(peerRPC("nope", ip), nil, info, func(context.Context, any) (any, error) { return nil, nil })
	}

	// Token válido do mesmo IP: deve passar normalmente.
	handlerCalled := false
	if _, err := interceptor(peerRPC(token, ip), nil, info, func(context.Context, any) (any, error) {
		handlerCalled = true
		return "ok", nil
	}); err != nil {
		t.Fatalf("token válido rejeitado mesmo com bucket de auth inválida esgotado: %v", err)
	}
	if !handlerCalled {
		t.Error("handler deveria ter sido chamado")
	}
}

// --- advanceAutoShutdown: gating EXP-45 ---

// TestAdvanceAutoShutdown_UnknownCountDoesNotAdvance (EXP-45): com erro na
// contagem (RCON/parse), o ciclo é pulado — NUNCA trata como 0 players e
// nunca inicia/avança/reseta o countdown.
func TestAdvanceAutoShutdown_UnknownCountDoesNotAdvance(t *testing.T) {
	base := time.Now()
	errParse := fmt.Errorf("resposta 'list' incoerente")

	t.Run("estado zerado continua zerado", func(t *testing.T) {
		st := &autoShutdownState{}
		d := advanceAutoShutdown(st, 30, base, 0, errParse)
		if d != autoShutdownUnknown {
			t.Fatalf("decisão = %v, esperado autoShutdownUnknown", d)
		}
		if !st.emptySince.IsZero() {
			t.Error("emptySince não deveria ser iniciado com contagem desconhecida")
		}
	})

	t.Run("countdown em andamento permanece intacto", func(t *testing.T) {
		st := &autoShutdownState{emptySince: base.Add(-10 * time.Minute)}
		d := advanceAutoShutdown(st, 30, base, 0, errParse)
		if d != autoShutdownUnknown {
			t.Fatalf("decisão = %v, esperado autoShutdownUnknown", d)
		}
		if !st.emptySince.Equal(base.Add(-10 * time.Minute)) {
			t.Errorf("emptySince foi alterado com contagem desconhecida: %v", st.emptySince)
		}
	})

	t.Run("countdown não dispara mesmo após janela com erro", func(t *testing.T) {
		// Janela já decorrida, mas o ciclo atual é UNKNOWN → não para o servidor.
		st := &autoShutdownState{emptySince: base.Add(-2 * time.Hour)}
		d := advanceAutoShutdown(st, 30, base, 0, fmt.Errorf("rcon timeout"))
		if d != autoShutdownUnknown {
			t.Fatalf("decisão = %v, esperado autoShutdownUnknown", d)
		}
	})
}

// TestAdvanceAutoShutdown_HappyPath (EXP-45): sequência confirmada — begin →
// idle → stop; players resetam o countdown.
func TestAdvanceAutoShutdown_HappyPath(t *testing.T) {
	base := time.Now()
	st := &autoShutdownState{}

	if d := advanceAutoShutdown(st, 30, base, 0, nil); d != autoShutdownBegin {
		t.Fatalf("primeira observação vazia: decisão = %v, esperado Begin", d)
	}
	if st.emptySince.IsZero() {
		t.Fatal("emptySince deveria ter sido iniciado")
	}

	if d := advanceAutoShutdown(st, 30, base.Add(10*time.Minute), 0, nil); d != autoShutdownIdle {
		t.Fatalf("dentro da janela: decisão = %v, esperado Idle", d)
	}

	// Player entrou → reset.
	if d := advanceAutoShutdown(st, 30, base.Add(15*time.Minute), 2, nil); d != autoShutdownReset {
		t.Fatalf("com players: decisão = %v, esperado Reset", d)
	}
	if !st.emptySince.IsZero() {
		t.Error("emptySince deveria ter sido resetado com players online")
	}

	// Vazio de novo → begin → idle → stop após a janela completa.
	if d := advanceAutoShutdown(st, 30, base.Add(20*time.Minute), 0, nil); d != autoShutdownBegin {
		t.Fatalf("re-begin: decisão = %v, esperado Begin", d)
	}
	if d := advanceAutoShutdown(st, 30, base.Add(49*time.Minute), 0, nil); d != autoShutdownIdle {
		t.Fatalf("janela quase completa: decisão = %v, esperado Idle", d)
	}
	if d := advanceAutoShutdown(st, 30, base.Add(50*time.Minute), 0, nil); d != autoShutdownStop {
		t.Fatalf("janela completa: decisão = %v, esperado Stop", d)
	}
	if !st.emptySince.IsZero() {
		t.Error("emptySince deveria ter sido resetado após o Stop")
	}
	if st.triggeredAt.IsZero() {
		t.Error("triggeredAt deveria ter sido registrado")
	}
}

// --- console stream deadline (EXP-47) ---

func TestConsoleStreamDeadline(t *testing.T) {
	tests := []struct {
		name string
		secs int
		want time.Duration
	}{
		{"unset usa default", 0, 5 * time.Minute},
		{"negativo usa default", -5, 5 * time.Minute},
		{"valor válido", 3600, time.Hour},
		{"mínimo", 60, 60 * time.Second},
		{"abaixo do mínimo é clampado", 30, 60 * time.Second},
		{"máximo", 86400, 24 * time.Hour},
		{"acima do máximo é clampado", 100000, 24 * time.Hour},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(false)
			s.cfg.Features.Console.StreamDeadlineSeconds = tc.secs
			if got := s.consoleStreamDeadline(); got != tc.want {
				t.Errorf("consoleStreamDeadline() = %v, esperado %v", got, tc.want)
			}
		})
	}
}

// TestConsoleDeadlineMarker (EXP-47): a linha marcadora permite ao cliente
// distinguir fechamento por deadline de fechamento por erro.
func TestConsoleDeadlineMarker(t *testing.T) {
	got := consoleDeadlineMarker(5 * time.Minute)
	want := "[crias-agent] console stream deadline reached (300s); reconnect to continue"
	if got != want {
		t.Errorf("marker = %q, esperado %q", got, want)
	}
}

// fakeConsoleStream registra cada ConsoleLine enviado — usado nos testes de
// streamConsoleLines (o loop de stream extraído do StreamConsole, EXP-47).
type fakeConsoleStream struct {
	grpc.ServerStream
	mu   sync.Mutex
	sent []*criasv1.ConsoleLine
}

func (f *fakeConsoleStream) Send(l *criasv1.ConsoleLine) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sent = append(f.sent, l)
	return nil
}

func (f *fakeConsoleStream) lines() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]string, len(f.sent))
	for i, l := range f.sent {
		out[i] = l.Line
	}
	return out
}

// waitForLine espera (com timeout) até que a linha apareça no stream fake.
func waitForLine(t *testing.T, fs *fakeConsoleStream, want string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, l := range fs.lines() {
			if l == want {
				return
			}
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("linha %q não chegou ao stream em 5s; linhas recebidas: %v", want, fs.lines())
}

// scriptedReader entrega chunks pré-programados e depois bloqueia até ser
// liberado — permite testar streamConsoleLines de forma determinística (um
// io.Pipe pode coalescer writes consecutivos num único Read, quebrando a
// sincronização do teste).
type scriptedReader struct {
	mu     sync.Mutex
	chunks [][]byte
	// unblock é fechado pelo teste para liberar o Read que esgotou os chunks.
	unblock chan struct{}
	// blocked é fechado (uma vez) quando o reader fica sem chunks — prova que
	// o loop já processou todos os chunks entregues (o próximo Read só é
	// agendado depois que o resultado anterior foi processado, buf incluso).
	blocked chan struct{}
}

func newScriptedReader(chunks ...string) *scriptedReader {
	r := &scriptedReader{
		unblock: make(chan struct{}),
		blocked: make(chan struct{}),
	}
	for _, c := range chunks {
		r.chunks = append(r.chunks, []byte(c))
	}
	return r
}

func (r *scriptedReader) Read(p []byte) (int, error) {
	r.mu.Lock()
	if len(r.chunks) > 0 {
		c := r.chunks[0]
		r.chunks = r.chunks[1:]
		r.mu.Unlock()
		return copy(p, c), nil
	}
	// Sem chunks: sinaliza idle (uma vez) e bloqueia até o teste liberar.
	close(r.blocked)
	r.mu.Unlock()
	<-r.unblock
	return 0, errors.New("scripted reader liberado")
}

// TestStreamConsoleLines_DeadlineMarker (EXP-47): quando o deadline server-side
// dispara (flag setada ANTES do cancel, mesma ordem do timer do StreamConsole),
// a linha parcial em buffer é enviada seguida do marcador de reconexão — sem
// depender de journalctl, o loop extraído é exercitado com um reader scriptado.
func TestStreamConsoleLines_DeadlineMarker(t *testing.T) {
	r := newScriptedReader("first line\n", "partial without newline")
	defer close(r.unblock)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var deadlineFired atomic.Bool

	fs := &fakeConsoleStream{}
	done := make(chan error, 1)
	go func() {
		// O deadline aqui só alimenta o texto do marcador (300s).
		done <- streamConsoleLines(ctx, r, fs, 300*time.Second, &deadlineFired)
	}()

	// Espera o reader ficar sem chunks: a partir daqui o "partial without
	// newline" já foi processado pelo loop e está em buf (sem newline).
	select {
	case <-r.blocked:
	case <-time.After(5 * time.Second):
		t.Fatal("scripted reader não esgotou os chunks")
	}
	waitForLine(t, fs, "first line")

	// Dispara o deadline do servidor: flag ANTES do cancel (mesma ordem do timer).
	deadlineFired.Store(true)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("esperado context.Canceled, obtido %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("streamConsoleLines não retornou após o deadline")
	}

	lines := fs.lines()
	if len(lines) != 3 {
		t.Fatalf("esperado 3 linhas, obtido %v", lines)
	}
	if lines[0] != "first line" {
		t.Errorf("lines[0] = %q, esperado %q", lines[0], "first line")
	}
	if lines[1] != "partial without newline" {
		t.Errorf("lines[1] = %q, esperado a parcial em buffer", lines[1])
	}
	if marker := consoleDeadlineMarker(300 * time.Second); lines[2] != marker {
		t.Errorf("lines[2] = %q, esperado marcador %q", lines[2], marker)
	}
}

// TestStreamConsoleLines_ClientCancelNoMarker (EXP-47): cancelamento do
// CLIENTE (flag não setada) fecha o stream SEM o marcador de deadline — só o
// deadline server-side emite o marcador.
func TestStreamConsoleLines_ClientCancelNoMarker(t *testing.T) {
	pr, pw := io.Pipe()
	defer pr.Close()
	defer pw.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var deadlineFired atomic.Bool

	fs := &fakeConsoleStream{}
	done := make(chan error, 1)
	go func() {
		done <- streamConsoleLines(ctx, pr, fs, 300*time.Second, &deadlineFired)
	}()

	if _, err := pw.Write([]byte("first line\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	waitForLine(t, fs, "first line")

	// Cancelamento do cliente: SEM setar a flag do deadline.
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("esperado context.Canceled, obtido %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("streamConsoleLines não retornou após cancelamento")
	}

	for _, l := range fs.lines() {
		if strings.Contains(l, "crias-agent") {
			t.Errorf("marcador de deadline não deveria ser enviado em cancelamento do cliente: %q", l)
		}
	}
}

// TestStreamConsoleLines_EOFFlushesPartial: EOF no journalctl faz flush da
// linha parcial em buffer e fecha o stream normalmente (sem erro).
func TestStreamConsoleLines_EOFFlushesPartial(t *testing.T) {
	pr, pw := io.Pipe()
	defer pr.Close()

	fs := &fakeConsoleStream{}
	done := make(chan error, 1)
	go func() {
		done <- streamConsoleLines(context.Background(), pr, fs, 300*time.Second, &atomic.Bool{})
	}()

	// Parcial sem newline; o Write só retorna depois que o read a consumiu.
	if _, err := pw.Write([]byte("partial data")); err != nil {
		t.Fatalf("write: %v", err)
	}
	// EOF: o próximo read retorna io.EOF → flush + return nil.
	if err := pw.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("esperado nil no EOF, obtido %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("streamConsoleLines não retornou após EOF")
	}

	lines := fs.lines()
	if len(lines) != 1 || lines[0] != "partial data" {
		t.Errorf("linhas = %v, esperado [partial data]", lines)
	}
}

// --- unit state no GetHealth (EXP-53) ---

// TestClassifyUnitState (EXP-53): parsing da saída do `systemctl is-active`.
func TestClassifyUnitState(t *testing.T) {
	exitErr := fmt.Errorf("exit status 3") // simula ExitError sem depender de exec
	tests := []struct {
		name string
		out  string
		err  error
		want unitState
	}{
		{"exit 0", "active\n", nil, unitStateActive},
		{"printed active with error (defensive)", "active\n", exitErr, unitStateActive},
		{"inactive", "inactive\n", exitErr, unitStateInactive},
		{"failed", "failed\n", exitErr, unitStateInactive},
		{"activating", "activating\n", exitErr, unitStateInactive},
		{"unknown state", "unknown\n", exitErr, unitStateInactive},
		{"no output binary missing", "", fmt.Errorf("exec: no such file"), unitStateUnknown},
		{"no output with exit error", "", exitErr, unitStateUnknown},
		{"garbage output", "System has not been booted with systemd\n", exitErr, unitStateUnknown},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := classifyUnitState(tc.out, tc.err); got != tc.want {
				t.Errorf("classifyUnitState(%q, %v) = %v, esperado %v", tc.out, tc.err, got, tc.want)
			}
		})
	}
}

// TestGetHealth_RequiresActiveUnit (EXP-53): com a porta em escuta (simulada
// por um listener real) e RCON desabilitado, o veredito healthy deve exigir a
// unit ativa — a porta sozinha (ex.: outro processo na porta do jogo) não basta.
func TestGetHealth_RequiresActiveUnit(t *testing.T) {
	// Abre um listener real para simular a porta do jogo em escuta.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	gamePort := ln.Addr().(*net.TCPAddr).Port

	tests := []struct {
		name        string
		state       unitState
		wantHealthy bool
		wantMsgPart string
	}{
		{
			name:        "unit ativa + porta escutando = healthy",
			state:       unitStateActive,
			wantHealthy: true,
			wantMsgPart: "healthy",
		},
		{
			name:        "unit inativa (outro processo na porta) = unhealthy",
			state:       unitStateInactive,
			wantHealthy: false,
			wantMsgPart: "unit systemd não está ativa",
		},
		{
			name:        "unit desconhecida mantém fallback porta+rcon",
			state:       unitStateUnknown,
			wantHealthy: true,
			wantMsgPart: "desconhecido",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s := newTestServer(false)
			s.cfg.Server.ServerPort = gamePort
			s.checkUnitState = func(ctx context.Context, service string) unitState {
				return tc.state
			}

			resp, err := s.GetHealth(context.Background(), &criasv1.GetHealthRequest{})
			if err != nil {
				t.Fatalf("GetHealth: %v", err)
			}
			if !resp.PortListening {
				t.Fatal("pré-condição: porta deveria estar em escuta (listener real)")
			}
			if resp.Healthy != tc.wantHealthy {
				t.Errorf("Healthy = %v, esperado %v (message=%q)", resp.Healthy, tc.wantHealthy, resp.Message)
			}
			if !strings.Contains(resp.Message, tc.wantMsgPart) {
				t.Errorf("Message = %q, deveria conter %q", resp.Message, tc.wantMsgPart)
			}
		})
	}
}

// TestGetHealth_PortClosedIsUnhealthy (EXP-53): sanity — porta fechada continua
// unhealthy independentemente da unit.
func TestGetHealth_PortClosedIsUnhealthy(t *testing.T) {
	s := newTestServer(false)
	// Porta arbitrária sem nada escutando (probabilidade de colisão ínfima).
	s.cfg.Server.ServerPort = 1
	s.checkUnitState = func(ctx context.Context, service string) unitState {
		return unitStateActive
	}

	resp, err := s.GetHealth(context.Background(), &criasv1.GetHealthRequest{})
	if err != nil {
		t.Fatalf("GetHealth: %v", err)
	}
	if resp.Healthy {
		t.Errorf("Healthy = true com porta fechada, esperado false (message=%q)", resp.Message)
	}
	if !strings.Contains(resp.Message, "não está em escuta") {
		t.Errorf("Message = %q, deveria mencionar porta não em escuta", resp.Message)
	}
}

// --- withDeadline ---

func TestWithDeadline_NoClientDeadline(t *testing.T) {
	ctx := context.Background()
	ctx2, cancel := withDeadline(ctx, 30*0)
	defer cancel()
	// Como 0ns é menor que qualquer coisa, deve retornar imediatamente.
	// Mas o ponto principal é não panicar.
	_ = ctx2
}

func TestWithDeadline_RespectsClientDeadline(t *testing.T) {
	// Cliente setou deadline menor — deve respeitar (WithCancel, não alonga).
	ctx, cancel := context.WithTimeout(context.Background(), 1)
	defer cancel()
	ctx2, cancel2 := withDeadline(ctx, time.Second)
	defer cancel2()
	// 2E-010: ctx2 vem de context.WithCancel (não WithDeadline), então
	// ctx2.Deadline() retorna (zero, false) — o deadline fica no parent.
	// Verificamos que o parent ainda tem deadline (não foi removido) e
	// que ctx2 é cancelado quando o parent expira.
	if _, ok := ctx.Deadline(); !ok {
		t.Errorf("ctx (parent) deve ter deadline — withDeadline não deve remover do parent")
	}
	// ctx2 não deve ter deadline próprio — com WithCancel, ele herda
	// cancelamento mas não o deadline direto.
	if _, ok := ctx2.Deadline(); ok {
		// Isso não é estritamente um erro (poderia ser), mas documenta
		// o comportamento esperado da implementação atual.
		t.Logf("ctx2 tem deadline próprio — comportamento diferente do esperado")
	}
	// Verifica que ctx2 é cancelado quando o parent expira (deadline 1ns).
	time.Sleep(5 * time.Millisecond)
	if ctx2.Err() == nil {
		t.Errorf("ctx2 deveria estar cancelado após parent expirar (deadline 1ns)")
	}
}

// --- Compile-time checks ---

// Compile-time check: *fakeServerStream deve implementar grpc.ServerStream.
var _ grpc.ServerStream = (*fakeServerStream)(nil)

// errSentinel para comparações em testes futuros.
var errSentinel = errors.New("test sentinel")
