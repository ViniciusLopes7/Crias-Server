// Package config carrega /etc/crias/agent.yaml.
package config

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// authTokenRegex valida o formato do token de auth: 64 caracteres hex
// minúsculos (256 bits de entropia), conforme gerado por `openssl rand -hex 32`.
// GO-011: rejeita placeholders e tokens fracos.
var authTokenRegex = regexp.MustCompile(`^[0-9a-f]{64}$`)

// serviceNameRegex valida nomes de serviço systemd (apenas chars seguros).
// GO-022: defense-in-depth contra typos e config maliciosa.
var serviceNameRegex = regexp.MustCompile(`^[a-zA-Z0-9_.@-]+$`)

// Config é a estrutura raiz do agent.yaml.
type Config struct {
	Agent    AgentConfig    `yaml:"agent"`
	Server   ServerConfig   `yaml:"server"`
	Features FeaturesConfig `yaml:"features"`
}

// AgentConfig controla o listener gRPC.
type AgentConfig struct {
	BindAddress string `yaml:"bind_address"`
	Port        int    `yaml:"port"`
	AuthToken   string `yaml:"auth_token"`
	// TLSCert e TLSKey habilitam TLS/mTLS no servidor gRPC.
	// Obrigatórios se bind_address != 127.0.0.1/::1/localhost (GO-005).
	// Caminhos para arquivos PEM no disco.
	TLSCert string `yaml:"tls_cert"`
	TLSKey  string `yaml:"tls_key"`
}

// ServerConfig aponta para o stack ativo e como delegar comandos.
type ServerConfig struct {
	Stack         string     `yaml:"stack"`          // "minecraft" | "terraria"
	ServiceName   string     `yaml:"service_name"`   // ex.: "minecraft"
	ManagerScript string     `yaml:"manager_script"` // /opt/minecraft-server/mc-manager.sh
	ServerDir     string     `yaml:"server_dir"`     // /opt/minecraft-server
	ServerPort    int        `yaml:"server_port"`    // porta do servidor de jogo (25565 MC, 7777 TT)
	HardwareTier  string     `yaml:"hardware_tier"`  // LOW/MID/HIGH (replicado do install.sh)
	RCON          RCONConfig `yaml:"rcon"`
}

// RCONConfig habilita consultas de players e say.
type RCONConfig struct {
	Enabled  bool   `yaml:"enabled"`
	Host     string `yaml:"host"`
	Port     int    `yaml:"port"`
	Password string `yaml:"password"`
}

// FeaturesConfig controla features opcionais do agente.
type FeaturesConfig struct {
	AutoShutdown AutoShutdownConfig `yaml:"auto_shutdown"`
	HealthCheck  HealthCheckConfig  `yaml:"health_check"`
}

// AutoShutdownConfig: se enabled, desliga servidor quando vazio por N minutos.
type AutoShutdownConfig struct {
	Enabled      bool `yaml:"enabled"`
	EmptyMinutes int  `yaml:"empty_minutes"`
}

// HealthCheckConfig: verifica saúde a cada N segundos, passivo (não reinicia).
type HealthCheckConfig struct {
	IntervalSeconds int  `yaml:"interval_seconds"`
	Passive         bool `yaml:"passive"`
}

// Load lê e faz parse do agent.yaml no caminho fornecido.
// Retorna erro se o arquivo não existir, for inválido, ou contiver
// configuração insegura (token fraco, bind inseguro sem TLS, etc.).
//
// GO-005: bind_address != localhost exige TLS.
// GO-011: auth_token deve ter 64 chars hex (rejeita placeholder).
// GO-022: service_name validado por regex.
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("ler %s: %w", path, err)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse yaml %s: %w", path, err)
	}

	// Defaults sane se campos obrigatórios estiverem vazios.
	if cfg.Agent.BindAddress == "" {
		cfg.Agent.BindAddress = "127.0.0.1"
	}
	if cfg.Agent.Port == 0 {
		cfg.Agent.Port = 8473
	}
	if cfg.Features.AutoShutdown.EmptyMinutes == 0 {
		cfg.Features.AutoShutdown.EmptyMinutes = 30
	}
	if cfg.Features.HealthCheck.IntervalSeconds == 0 {
		cfg.Features.HealthCheck.IntervalSeconds = 300
	}
	if cfg.Server.Stack == "" {
		cfg.Server.Stack = "minecraft"
	}

	// GO-011: valida formato do auth_token (64 hex chars).
	// Rejeita placeholder e tokens fracos.
	if cfg.Agent.AuthToken == "" {
		return nil, fmt.Errorf("agent.auth_token não pode ser vazio")
	}
	if cfg.Agent.AuthToken == "CHANGE_ME_TO_RANDOM_64_HEX_CHARS" {
		return nil, fmt.Errorf("agent.auth_token ainda é o placeholder — gere com: openssl rand -hex 32")
	}
	if !authTokenRegex.MatchString(cfg.Agent.AuthToken) {
		return nil, fmt.Errorf("agent.auth_token deve ter 64 caracteres hex minúsculos (gerado por `openssl rand -hex 32`)")
	}

	// GO-022: valida service_name contra regex de chars seguros.
	if cfg.Server.ServiceName == "" {
		return nil, fmt.Errorf("server.service_name não pode ser vazio")
	}
	if !serviceNameRegex.MatchString(cfg.Server.ServiceName) {
		return nil, fmt.Errorf("server.service_name %q contém caracteres inválidos (use apenas [a-zA-Z0-9_.@-])", cfg.Server.ServiceName)
	}

	// GO-005: bind_address != localhost exige TLS.
	// Defense-in-depth: previne expose do token em cleartext na rede.
	if !isLoopback(cfg.Agent.BindAddress) {
		if cfg.Agent.TLSCert == "" || cfg.Agent.TLSKey == "" {
			return nil, fmt.Errorf(
				"agent.bind_address %q requer TLS (configure tls_cert e tls_key, ou use 127.0.0.1)",
				cfg.Agent.BindAddress,
			)
		}
	}

	// GO-069: rejeita placeholders em rcon.password.
	if cfg.Server.RCON.Enabled {
		if cfg.Server.RCON.Password == "" {
			return nil, fmt.Errorf("server.rcon.password não pode ser vazio quando rcon.enabled=true")
		}
		if strings.HasPrefix(cfg.Server.RCON.Password, "CHANGE_ME_") {
			return nil, fmt.Errorf("server.rcon.password ainda é o placeholder — defina o password real de server.properties")
		}
	}

	// GO-058: valida RCON host/port se habilitado.
	if cfg.Server.RCON.Enabled {
		if cfg.Server.RCON.Host == "" {
			cfg.Server.RCON.Host = "127.0.0.1"
		}
		if cfg.Server.RCON.Port == 0 {
			return nil, fmt.Errorf("server.rcon.port não pode ser 0 quando rcon.enabled=true")
		}
	}

	return &cfg, nil
}

// isLoopback retorna true se o endereço for loopback (127.0.0.1, ::1, localhost).
func isLoopback(addr string) bool {
	switch addr {
	case "127.0.0.1", "::1", "localhost":
		return true
	default:
		return false
	}
}

// DefaultConfigPath retorna o caminho padrão do agent.yaml.
func DefaultConfigPath() string {
	if p := os.Getenv("CRIAS_AGENT_CONFIG"); p != "" {
		return p
	}
	return "/etc/crias/agent.yaml"
}
