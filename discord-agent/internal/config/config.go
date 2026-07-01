// Package config carrega /etc/crias/agent.yaml.
package config

import (
        "fmt"
        "os"

        "gopkg.in/yaml.v3"
)

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
}

// ServerConfig aponta para o stack ativo e como delegar comandos.
type ServerConfig struct {
        Stack         string    `yaml:"stack"`           // "minecraft" | "terraria"
        ServiceName   string    `yaml:"service_name"`    // ex.: "minecraft"
        ManagerScript string    `yaml:"manager_script"`  // /opt/minecraft-server/mc-manager.sh
        ServerDir     string    `yaml:"server_dir"`      // /opt/minecraft-server
        ServerPort    int       `yaml:"server_port"`     // porta do servidor de jogo (25565 MC, 7777 TT)
        HardwareTier  string    `yaml:"hardware_tier"`   // LOW/MID/HIGH (replicado do install.sh)
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
// Retorna erro se o arquivo não existir ou for inválido.
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

        if cfg.Agent.AuthToken == "" {
                return nil, fmt.Errorf("agent.auth_token não pode ser vazio")
        }
        if cfg.Server.ServiceName == "" {
                return nil, fmt.Errorf("server.service_name não pode ser vazio")
        }

        return &cfg, nil
}

// DefaultConfigPath retorna o caminho padrão do agent.yaml.
func DefaultConfigPath() string {
        if p := os.Getenv("CRIAS_AGENT_CONFIG"); p != "" {
                return p
        }
        return "/etc/crias/agent.yaml"
}
