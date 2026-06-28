// Package rcon fornece um cliente RCON para o agente consultar players
// e executar comandos no servidor Minecraft.
package rcon

import (
        "fmt"
        "strings"
        "sync"
        "time"

        "github.com/gorcon/rcon"
)

// Client wraps uma conexão RCON com cache curto (30s) para evitar
// reconnects desnecessários. É seguro para uso concorrente (múltiplas
// goroutines podem chamar Execute simultaneamente).
type Client struct {
        host     string
        port     int
        password string
        enabled  bool

        // mu protege conn e lastUse contra data races.
        mu       sync.Mutex
        conn     *rcon.Conn
        lastUse  time.Time
        cacheTTL time.Duration

        // Hooks para testes (podem ser substituídos).
        dialer func(host string, port int, password string) (*rcon.Conn, error)
}

// NewClient cria um cliente RCON. Se enabled=false, todas as operações
// retornam ErrRCONDisabled.
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

// ErrRCONDisabled é retornado quando RCON está desabilitado na config.
var ErrRCONDisabled = fmt.Errorf("rcon desabilitado na configuração")

// defaultDialer abre conexão RCON real.
// Nota: gorcon/rcon v1.3.5 não suporta WithDialTimeout; o timeout default
// interno da lib é 5s. Para versões mais recentes que suportem a opção,
// pode ser adicionada de volta.
func defaultDialer(host string, port int, password string) (*rcon.Conn, error) {
        addr := fmt.Sprintf("%s:%d", host, port)
        return rcon.Dial(addr, password)
}

// Execute executa um comando RCON. Reusa conexão se ainda válida (cache).
// Seguro para uso concorrente: serializa acessos via c.mu.
func (c *Client) Execute(command string) (string, error) {
        if !c.enabled {
                return "", ErrRCONDisabled
        }

        c.mu.Lock()
        defer c.mu.Unlock()

        // Reusa conexão se foi usada nos últimos cacheTTL segundos.
        if c.conn != nil && time.Since(c.lastUse) < c.cacheTTL {
                c.lastUse = time.Now()
                out, err := c.conn.Execute(command)
                if err == nil {
                        return out, nil
                }
                // Conexão morreu — fecha e tenta reconectar.
                if closeErr := c.conn.Close(); closeErr != nil {
                        // Log best-effort; erro de Close em conexão morta é esperado.
                        _ = closeErr
                }
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
                return "", fmt.Errorf("executar rcon %q: %w", command, err)
        }
        return out, nil
}

// Close fecha a conexão RCON se aberta. Seguro para uso concorrente.
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

// PlayerList consulta RCON "list" e parseia a resposta.
// Resposta típica do Minecraft: "There are 2 of a max of 20 players online: player1, player2"
// Retorna (players, max_players, error).
func (c *Client) PlayerList() ([]string, int, error) {
        out, err := c.Execute("list")
        if err != nil {
                return nil, 0, err
        }
        return parseListResponse(out), parseMaxPlayers(out), nil
}

// parseListResponse extrai lista de players da resposta do RCON "list".
// Formato: "There are N of a max of M players online: p1, p2, p3"
// Se não houver players online: "There are 0 of a max of M players online: "
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

// parseMaxPlayers extrai o número máximo de players da resposta "list".
func parseMaxPlayers(raw string) int {
        // Procura por "max of N players"
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

// whitelistedCommands é declarado em package-level (imutável) para evitar
// realocação a cada chamada de IsCommandAllowed em hot paths.
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

// WhitelistedCommands retorna uma cópia do map de comandos permitidos.
// Para lookup em hot paths, use IsCommandAllowed (mais eficiente).
func WhitelistedCommands() map[string]bool {
        // Retorna cópia para evitar mutação externa do mapa package-level.
        out := make(map[string]bool, len(whitelistedCommands))
        for k, v := range whitelistedCommands {
                out[k] = v
        }
        return out
}

// IsCommandAllowed verifica se o primeiro token do comando é whitelistado.
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
