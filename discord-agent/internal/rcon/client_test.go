// Package rcon tests.
package rcon

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorcon/rcon"
)

// --- parseListResponse (EXP-45) ---

func TestParseListResponse_WithPlayers(t *testing.T) {
	raw := "There are 2 of a max of 20 players online: Steve, Alex"
	players, max, err := parseListResponse(raw)
	if err != nil {
		t.Fatalf("esperado nil error, obtido %v", err)
	}
	if len(players) != 2 {
		t.Fatalf("esperado 2 players, obtido %d: %v", len(players), players)
	}
	if players[0] != "Steve" {
		t.Errorf("players[0] = %q, esperado Steve", players[0])
	}
	if players[1] != "Alex" {
		t.Errorf("players[1] = %q, esperado Alex", players[1])
	}
	if max != 20 {
		t.Errorf("max = %d, esperado 20", max)
	}
}

func TestParseListResponse_NoPlayers(t *testing.T) {
	// Formato vanilla com servidor vazio (com e sem espaço trailing).
	for _, raw := range []string{
		"There are 0 of a max of 20 players online: ",
		"There are 0 of a max of 20 players:",
	} {
		players, max, err := parseListResponse(raw)
		if err != nil {
			t.Fatalf("parseListResponse(%q): esperado nil error, obtido %v", raw, err)
		}
		if len(players) != 0 {
			t.Fatalf("parseListResponse(%q): esperado 0 players, obtido %d: %v", raw, len(players), players)
		}
		if max != 20 {
			t.Errorf("parseListResponse(%q): max = %d, esperado 20", raw, max)
		}
	}
}

// TestParseListResponse_ValidFormats cobre os formatos reais do "list":
// inglês (1.13+ e 1.12-), variantes localizadas coerentes e formatos de proxy.
func TestParseListResponse_ValidFormats(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		players []string
		max     int
	}{
		{
			name:    "modern with players",
			raw:     "There are 2 of a max of 20 players: Steve, Alex",
			players: []string{"Steve", "Alex"},
			max:     20,
		},
		{
			name:    "modern single player",
			raw:     "There are 1 of a max of 20 players: Steve",
			players: []string{"Steve"},
			max:     20,
		},
		{
			name:    "legacy with online suffix",
			raw:     "There are 2 of a max of 20 players online: Steve, Alex",
			players: []string{"Steve", "Alex"},
			max:     20,
		},
		{
			name:    "localized (pt-BR) coherent",
			raw:     "Existem 2 de um máximo de 20 jogadores: Steve, Alex",
			players: []string{"Steve", "Alex"},
			max:     20,
		},
		{
			name:    "proxy style count/max",
			raw:     "2/20 players online: Steve, Alex",
			players: []string{"Steve", "Alex"},
			max:     20,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			players, max, err := parseListResponse(tc.raw)
			if err != nil {
				t.Fatalf("esperado nil error, obtido %v", err)
			}
			if len(players) != len(tc.players) {
				t.Fatalf("esperado %d players, obtido %d: %v", len(tc.players), len(players), players)
			}
			for i := range tc.players {
				if players[i] != tc.players[i] {
					t.Errorf("players[%d] = %q, esperado %q", i, players[i], tc.players[i])
				}
			}
			if max != tc.max {
				t.Errorf("max = %d, esperado %d", max, tc.max)
			}
		})
	}
}

// TestParseListResponse_Invalid garante que respostas não-reconhecidas
// retornam ERRO (nunca lista vazia com error nil) — antes do EXP-45 uma
// resposta malformada era tratada como "0 players", podendo parar um
// servidor ocupado via auto-shutdown.
func TestParseListResponse_Invalid(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{"empty response", ""},
		{"whitespace only", "   "},
		{"no colon", "malformed response without colon"},
		{"garbage", "§aSome random server output"},
		{"localized garbage without separator", "Erro interno do servidor"},
		{"garbage with colon but no counts", "Some garbage output: with colon"},
		{"garbage with one number", "Error 500: internal"},
		// Incoerência: declara 2 mas lista 0 nomes (e vice-versa).
		{"declares 2 lists 0", "There are 2 of a max of 20 players: "},
		{"declares 2 lists 1", "There are 2 of a max of 20 players: Steve"},
		{"declares 0 lists 1", "There are 0 of a max of 20 players: Steve"},
		{"declares 0 lists 2", "There are 0 of a max of 20 players: Steve, Alex"},
		{"localized declares 2 lists 1", "Existem 2 de um máximo de 20 jogadores: Steve"},
		{"garbage with two numbers", "Error 500 503: internal"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			players, _, err := parseListResponse(tc.raw)
			if err == nil {
				t.Fatalf("parseListResponse(%q): esperado ERRO, obtido players=%v err=nil", tc.raw, players)
			}
			if players != nil {
				t.Errorf("parseListResponse(%q): players deve ser nil no erro, obtido %v", tc.raw, players)
			}
		})
	}
}

func TestIsCommandAllowed_Whitelisted(t *testing.T) {
	allowed := []string{
		"say Hello world",
		"list",
		"tell Steve hi",
		"tp Steve Alex",
		"weather rain",
		"give Steve diamond 64",
	}
	for _, cmd := range allowed {
		if !IsCommandAllowed(cmd) {
			t.Errorf("esperado que %q seja permitido", cmd)
		}
	}
}

func TestIsCommandAllowed_Dangerous(t *testing.T) {
	dangerous := []string{
		"stop",
		"op Steve",
		"deop Steve",
		"ban Steve",
		"pardon Steve",
		"reload",
		"",    // vazio
		"   ", // só espaços
	}
	for _, cmd := range dangerous {
		if IsCommandAllowed(cmd) {
			t.Errorf("esperado que %q seja BLOQUEADO", cmd)
		}
	}
}

func TestIsCommandAllowed_CaseInsensitive(t *testing.T) {
	if !IsCommandAllowed("SAY Hello") {
		t.Error("esperado SAY (uppercase) permitido")
	}
	if !IsCommandAllowed("Say Hello") {
		t.Error("esperado Say (mixed case) permitido")
	}
}

// TestNewClient_Defaults valida que NewClient não panica com config mínima.
func TestNewClient_Defaults(t *testing.T) {
	c := NewClient("127.0.0.1", 25575, "secret", true)
	if c == nil {
		t.Fatal("NewClient retornou nil")
	}
	if !c.enabled {
		t.Error("esperado enabled=true")
	}
}

func TestNewClient_Disabled(t *testing.T) {
	c := NewClient("127.0.0.1", 25575, "", false)
	_, err := c.Execute(context.Background(), "list")
	if err != ErrRCONDisabled {
		t.Errorf("esperado ErrRCONDisabled, obtido %v", err)
	}
}

// TestClient_Execute_Mock valida que Execute usa o dialer customizado e
// NÃO faz conexão de rede real (TST-004). Antes deste fix, o teste tentava
// conectar para invalid.example:9999, que em ambientes com DNS resolver
// wildcard (Docker, systemd-resolved) responde inesperadamente, fazendo o
// teste dar skip silencioso. Agora substituímos o dialer por uma função que
// sempre falha — teste é determinístico e não depende de rede.
func TestClient_Execute_Mock(t *testing.T) {
	c := NewClient("invalid.example", 9999, "wrong", true)
	// Substitui o dialer por um que sempre retorna erro — sem rede real.
	expectedErr := errors.New("connection refused (mock dialer)")
	c.dialer = func(host string, port int, password string) (*rcon.Conn, error) {
		return nil, expectedErr
	}

	_, err := c.Execute(context.Background(), "list")
	if err == nil {
		t.Fatal("esperado erro, obtido nil")
	}
	// Execute wrappa o erro do dialer com "conectar rcon: %w".
	if !strings.Contains(err.Error(), "conectar rcon") {
		t.Errorf("erro esperado deveria conter 'conectar rcon', obtido: %v", err)
	}
	// E o erro original deve estar wrapped (errors.Is funciona).
	if !errors.Is(err, expectedErr) {
		t.Errorf("erro original não preservado no wrap: %v", err)
	}
}

// TestClient_Execute_DisabledReturnsErrRCONDisabled garante que Execute com
// enabled=false retorna ErrRCONDisabled sem chamar o dialer (logo, sem rede).
func TestClient_Execute_DisabledReturnsErrRCONDisabled(t *testing.T) {
	c := NewClient("any.host", 1, "", false)
	// dialer permanece defaultDialer; não deve ser chamado porque enabled=false.
	_, err := c.Execute(context.Background(), "list")
	if err != ErrRCONDisabled {
		t.Errorf("esperado ErrRCONDisabled, obtido %v", err)
	}
}

// TestClient_Close_NoConn garante que Close em client sem conexão não panica.
func TestClient_Close_NoConn(t *testing.T) {
	c := NewClient("any.host", 1, "", true)
	if err := c.Close(); err != nil {
		t.Errorf("Close() em client sem conexão não deve retornar erro: %v", err)
	}
}

// --- Fake RCON server (CR-27) ---
//
// fakeRCONServer é um servidor RCON mínimo para os testes de timeout/abandono:
//   - hangAuth=true:        aceita TCP mas nunca responde o handshake de auth
//     (simula servidor que "congela" durante a conexão — o goroutine ficava
//     preso segurando o mutex, CR-27);
//   - commandResponse != "": responde comandos com o corpo configurado
//     (servidor funcional para testes de integração);
//   - caso contrário:       completa o auth mas nunca responde comandos
//     (simula servidor ocupado/travado no meio do I/O).

type fakeRCONServer struct {
	listener        net.Listener
	hangAuth        bool
	commandResponse string

	mu    sync.Mutex
	conns map[net.Conn]struct{}
}

// startFakeRCONServer sobe o servidor fake em 127.0.0.1 com porta efêmera.
// A limpeza (Close) é registrada via t.Cleanup.
func startFakeRCONServer(t *testing.T, hangAuth bool, commandResponse string) (host string, port int) {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &fakeRCONServer{
		listener:        l,
		hangAuth:        hangAuth,
		commandResponse: commandResponse,
		conns:           make(map[net.Conn]struct{}),
	}
	go s.serve()
	t.Cleanup(s.Close)
	tcpAddr := l.Addr().(*net.TCPAddr)
	return "127.0.0.1", tcpAddr.Port
}

func (s *fakeRCONServer) serve() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		s.conns[conn] = struct{}{}
		s.mu.Unlock()
		go s.handleConn(conn)
	}
}

// Close fecha o listener e todas as conexões — também destrava clientes
// bloqueados em leitura (os reads retornam erro de conexão fechada).
func (s *fakeRCONServer) Close() {
	_ = s.listener.Close()
	s.mu.Lock()
	for c := range s.conns {
		_ = c.Close()
	}
	s.mu.Unlock()
}

func (s *fakeRCONServer) handleConn(conn net.Conn) {
	defer func() {
		s.mu.Lock()
		_ = conn.Close()
		delete(s.conns, conn)
		s.mu.Unlock()
	}()

	if s.hangAuth {
		// Consome os bytes do cliente mas nunca responde o auth.
		_, _ = io.Copy(io.Discard, conn)
		return
	}

	// Handshake: lê o pacote SERVERDATA_AUTH e responde com um único
	// SERVERDATA_AUTH_RESPONSE (id=0, body vazio) — formato aceito pelo gorcon.
	if _, err := readFakePacket(conn); err != nil {
		return
	}
	if err := writeFakePacket(conn, 0, 2, ""); err != nil {
		return
	}

	for {
		pkt, err := readFakePacket(conn)
		if err != nil {
			return
		}
		if pkt.ptype != 2 { // SERVERDATA_EXECCOMMAND
			continue
		}
		if s.commandResponse != "" {
			if err := writeFakePacket(conn, 0, 0, s.commandResponse); err != nil {
				return
			}
		}
		// commandResponse == "": nunca responde — servidor "travado".
	}
}

// fakePacket é um pacote RCON cru (formato Source RCON, little-endian).
type fakePacket struct {
	id    int32
	ptype int32
	body  string
}

func readFakePacket(r io.Reader) (*fakePacket, error) {
	var hdr struct{ Size, ID, Type int32 }
	if err := binary.Read(r, binary.LittleEndian, &hdr); err != nil {
		return nil, err
	}
	if hdr.Size < 10 {
		return nil, fmt.Errorf("tamanho de pacote inválido: %d", hdr.Size)
	}
	// Size = id(4) + type(4) + body + padding(2); id/type já foram lidos.
	rest := make([]byte, hdr.Size-8)
	if _, err := io.ReadFull(r, rest); err != nil {
		return nil, err
	}
	return &fakePacket{id: hdr.ID, ptype: hdr.Type, body: string(rest[:len(rest)-2])}, nil
}

func writeFakePacket(w io.Writer, id, ptype int32, body string) error {
	size := int32(len(body) + 10)
	buf := bytes.NewBuffer(make([]byte, 0, int(size)+4))
	_ = binary.Write(buf, binary.LittleEndian, size)
	_ = binary.Write(buf, binary.LittleEndian, id)
	_ = binary.Write(buf, binary.LittleEndian, ptype)
	buf.WriteString(body)
	buf.Write([]byte{0x00, 0x00})
	_, err := w.Write(buf.Bytes())
	return err
}

// --- CR-27: timeout + abandono seguro ---

// TestClient_Execute_TimeoutAbandonsStuckIO (CR-27): contra um servidor que
// autentica mas nunca responde comandos, Execute deve retornar dentro do
// deadline do ctx, e um Execute subsequente NÃO pode ficar bloqueado para
// sempre pela operação abandonada (o conn travado é fechado via abandonConn).
func TestClient_Execute_TimeoutAbandonsStuckIO(t *testing.T) {
	host, port := startFakeRCONServer(t, false, "")

	c := NewClient(host, port, "secret", true)
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := c.Execute(ctx, "list")
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("esperado erro contra servidor que nunca responde")
	}
	if elapsed > 3*time.Second {
		t.Fatalf("Execute demorou %v; deveria retornar no deadline do ctx (~1.5s)", elapsed)
	}

	// O segundo Execute precisa retornar dentro do próprio deadline — prova
	// que a operação abandonada não segura ioMu/mu para sempre.
	ctx2, cancel2 := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel2()

	start2 := time.Now()
	_, err2 := c.Execute(ctx2, "list")
	elapsed2 := time.Since(start2)
	if err2 == nil {
		t.Fatal("esperado erro contra servidor que nunca responde")
	}
	if elapsed2 > 3*time.Second {
		t.Fatalf("segundo Execute demorou %v — operação abandonada está bloqueando o client", elapsed2)
	}
}

// TestClient_Execute_HungHandshakeDoesntWedgeClient (CR-27): servidor que
// aceita TCP mas nunca responde o auth. O dial fica preso (sem conn para
// fechar), mas fora dos locks — chamadas subsequentes continuam retornando
// dentro do deadline.
func TestClient_Execute_HungHandshakeDoesntWedgeClient(t *testing.T) {
	host, port := startFakeRCONServer(t, true, "")

	c := NewClient(host, port, "secret", true)
	defer c.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := c.Execute(ctx, "list")
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("esperado erro contra servidor que não responde auth")
	}
	if elapsed > 3*time.Second {
		t.Fatalf("Execute demorou %v; deveria retornar no deadline do ctx (~1.5s)", elapsed)
	}

	// Segunda chamada: o dialer dela fica enfileirado atrás do primeiro
	// (dialMu), mas a CHAMADA retorna no próprio deadline.
	ctx2, cancel2 := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel2()

	start2 := time.Now()
	_, err2 := c.Execute(ctx2, "list")
	elapsed2 := time.Since(start2)
	if err2 == nil {
		t.Fatal("esperado erro contra servidor que não responde auth")
	}
	if elapsed2 > 3*time.Second {
		t.Fatalf("segundo Execute demorou %v — dial abandonado está bloqueando o client", elapsed2)
	}
}

// TestClient_PlayerList_Integration: servidor fake funcional respondendo o
// "list" — valida o caminho completo Execute → parseListResponse, incluindo
// o erro de parse para resposta não-reconhecida (EXP-45).
func TestClient_PlayerList_Integration(t *testing.T) {
	host, port := startFakeRCONServer(t, false, "There are 2 of a max of 20 players: Steve, Alex")

	c := NewClient(host, port, "secret", true)
	defer c.Close()

	players, max, err := c.PlayerList(context.Background())
	if err != nil {
		t.Fatalf("PlayerList: %v", err)
	}
	if len(players) != 2 || players[0] != "Steve" || players[1] != "Alex" {
		t.Errorf("players = %v, esperado [Steve Alex]", players)
	}
	if max != 20 {
		t.Errorf("max = %d, esperado 20", max)
	}

	// Segunda chamada reutiliza a conexão em cache (mesma porta, sem nova
	// conexão) e deve funcionar igual.
	players2, _, err2 := c.PlayerList(context.Background())
	if err2 != nil {
		t.Fatalf("PlayerList (cached): %v", err2)
	}
	if len(players2) != 2 {
		t.Errorf("players (cached) = %v, esperado 2", players2)
	}
}

// TestClient_PlayerList_ParseErrorPropagates (EXP-45): uma resposta
// não-reconhecida do RCON deve vir como ERRO de PlayerList — nunca como
// "0 players" silencioso.
func TestClient_PlayerList_ParseErrorPropagates(t *testing.T) {
	host, port := startFakeRCONServer(t, false, "Internal server error, please try later")

	c := NewClient(host, port, "secret", true)
	defer c.Close()

	players, _, err := c.PlayerList(context.Background())
	if err == nil {
		t.Fatalf("esperado erro de parse, obtido players=%v err=nil", players)
	}
	if players != nil {
		t.Errorf("players deve ser nil no erro, obtido %v", players)
	}
}
