// Package config tests.
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad_ValidConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "abc123def456"
server:
  stack: "minecraft"
  service_name: "minecraft"
  manager_script: "/opt/minecraft-server/mc-manager.sh"
  server_dir: "/opt/minecraft-server"
  rcon:
    enabled: true
    host: "127.0.0.1"
    port: 25575
    password: "secret"
features:
  auto_shutdown:
    enabled: false
    empty_minutes: 30
  health_check:
    interval_seconds: 300
    passive: true
`), 0644)
	if err != nil {
		t.Fatalf("escrever config temporária: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load falhou: %v", err)
	}
	if cfg.Agent.AuthToken != "abc123def456" {
		t.Errorf("AuthToken = %q", cfg.Agent.AuthToken)
	}
	if cfg.Server.Stack != "minecraft" {
		t.Errorf("Stack = %q", cfg.Server.Stack)
	}
	if !cfg.Server.RCON.Enabled {
		t.Error("RCON.Enabled esperado true")
	}
}

func TestLoad_MissingAuthToken(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: ""
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por auth_token vazio")
	}
}

func TestLoad_MissingServiceName(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  auth_token: "token123"
server:
  stack: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por service_name vazio")
	}
}

func TestLoad_Defaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  auth_token: "token"
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Agent.BindAddress != "127.0.0.1" {
		t.Errorf("BindAddress default = %q, esperado 127.0.0.1", cfg.Agent.BindAddress)
	}
	if cfg.Agent.Port != 8473 {
		t.Errorf("Port default = %d, esperado 8473", cfg.Agent.Port)
	}
	if cfg.Features.AutoShutdown.EmptyMinutes != 30 {
		t.Errorf("EmptyMinutes default = %d, esperado 30", cfg.Features.AutoShutdown.EmptyMinutes)
	}
	if cfg.Features.HealthCheck.IntervalSeconds != 300 {
		t.Errorf("IntervalSeconds default = %d, esperado 300", cfg.Features.HealthCheck.IntervalSeconds)
	}
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/path/agent.yaml")
	if err == nil {
		t.Fatal("esperado erro para arquivo inexistente")
	}
}

func TestLoad_InvalidYAML(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte("not: valid: yaml: {{{"), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro de parse YAML")
	}
}

func TestDefaultConfigPath_EnvOverride(t *testing.T) {
	t.Setenv("CRIAS_AGENT_CONFIG", "/custom/path.yaml")
	if p := DefaultConfigPath(); p != "/custom/path.yaml" {
		t.Errorf("DefaultConfigPath = %q, esperado /custom/path.yaml", p)
	}
}

func TestDefaultConfigPath_Default(t *testing.T) {
	t.Setenv("CRIAS_AGENT_CONFIG", "")
	if p := DefaultConfigPath(); p != "/etc/crias/agent.yaml" {
		t.Errorf("DefaultConfigPath = %q, esperado /etc/crias/agent.yaml", p)
	}
}
