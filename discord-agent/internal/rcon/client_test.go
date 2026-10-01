// Package rcon tests.
package rcon

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/gorcon/rcon"
)

func TestParseListResponse_WithPlayers(t *testing.T) {
	raw := "There are 2 of a max of 20 players online: Steve, Alex"
	players := parseListResponse(raw)
	if len(players) != 2 {
		t.Fatalf("esperado 2 players, obtido %d: %v", len(players), players)
	}
	if players[0] != "Steve" {
		t.Errorf("players[0] = %q, esperado Steve", players[0])
	}
	if players[1] != "Alex" {
		t.Errorf("players[1] = %q, esperado Alex", players[1])
	}
}

func TestParseListResponse_NoPlayers(t *testing.T) {
	raw := "There are 0 of a max of 20 players online: "
	players := parseListResponse(raw)
	if len(players) != 0 {
		t.Fatalf("esperado 0 players, obtido %d: %v", len(players), players)
	}
}

func TestParseListResponse_Malformed(t *testing.T) {
	players := parseListResponse("malformed response without colon")
	if len(players) != 0 {
		t.Fatalf("esperado 0 players em resposta malformada, obtido %d", len(players))
	}
}

func TestParseMaxPlayers(t *testing.T) {
	tests := []struct {
		input string
		want  int
	}{
		{"There are 2 of a max of 20 players online: Steve, Alex", 20},
		{"There are 0 of a max of 100 players online: ", 100},
		{"malformed", 0},
	}
	for _, tc := range tests {
		got := parseMaxPlayers(tc.input)
		if got != tc.want {
			t.Errorf("parseMaxPlayers(%q) = %d, esperado %d", tc.input, got, tc.want)
		}
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
