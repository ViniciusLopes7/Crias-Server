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
        "testing"
        "time"

        "google.golang.org/grpc"
        "google.golang.org/grpc/codes"
        "google.golang.org/grpc/metadata"
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
        limiter := newAuthRateLimiter()
        if got := limiter.get(""); got != nil {
                t.Errorf("esperado nil para IP vazio, obtido %v", got)
        }
}

func TestAuthRateLimiter_CreatesLimiterForNewIP(t *testing.T) {
        limiter := newAuthRateLimiter()
        l1 := limiter.get("1.2.3.4")
        if l1 == nil {
                t.Fatal("esperado limiter não-nil para IP válido")
        }
        // Segunda chamada com mesmo IP deve retornar o mesmo limiter.
        l2 := limiter.get("1.2.3.4")
        if l1 != l2 {
                t.Error("esperado mesma instância de limiter para o mesmo IP")
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
