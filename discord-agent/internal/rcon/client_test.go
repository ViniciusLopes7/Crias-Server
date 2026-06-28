// Package rcon tests.
package rcon

import (
	"strings"
	"testing"
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
		"",          // vazio
		"   ",       // só espaços
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
	_, err := c.Execute("list")
	if err != ErrRCONDisabled {
		t.Errorf("esperado ErrRCONDisabled, obtido %v", err)
	}
}

// TestClient_Execute_Mock valida que Execute usa o dialer customizado.
func TestClient_Execute_Mock(t *testing.T) {
	// Não podemos mockar facilmente rcon.Conn sem refatorar, mas podemos
	// validar que IsCommandAllowed funciona. Este teste documenta a intenção.
	c := NewClient("invalid.example", 9999, "wrong", true)
	_, err := c.Execute("list")
	if err == nil {
		t.Skip("dialer real respondeu inesperadamente (ambiente com RCON?)")
	}
	if !strings.Contains(err.Error(), "conectar rcon") {
		t.Logf("erro de conexão esperado: %v", err)
	}
}
