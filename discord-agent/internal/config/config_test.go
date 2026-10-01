// Package config tests.
package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoad_ValidConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"  # 64 hex chars (valid format)
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
	if cfg.Agent.AuthToken != "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2" {
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
  auth_token: "b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2d3e4f5a6b1c2"  # 64 hex chars
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
  auth_token: "c1d2e3f4a5b6c1d2e3f4a5b6c1d2e3f4a5b6c1d2e3f4a5b6c1d2e3f4a5b6c1d2"  # 64 hex chars
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

// 2E-003: testes para as novas validações de segurança em Load().
// Cobrem: placeholder auth_token, token curto/malformado, TLS exigido
// quando bind_address não é loopback.

func TestLoad_PlaceholderAuthToken(t *testing.T) {
	// Placeholder token must be rejected to prevent deploying with default config.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "CHANGE_ME_TO_RANDOM_64_HEX_CHARS"
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por auth_token ainda ser placeholder")
	}
	if !strings.Contains(err.Error(), "placeholder") {
		t.Errorf("erro deve mencionar placeholder, got: %v", err)
	}
}

func TestLoad_ShortAuthToken(t *testing.T) {
	// 64 hex chars é o mínimo (256 bits). Token de 63 chars deve falhar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1"  # 63 chars
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por auth_token com menos de 64 chars")
	}
}

func TestLoad_UpperCaseAuthToken(t *testing.T) {
	// Regex exige apenas hex minúsculo. Uppercase deve falhar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"  # uppercase hex
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por auth_token com chars hex maiúsculos")
	}
}

func TestLoad_NonHexAuthToken(t *testing.T) {
	// 'g' não é hex (0-9, a-f). Token com 64 chars mas contendo 'g' deve falhar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "g1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"  # non-hex char 'g'
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por auth_token com char não-hex")
	}
}

func TestLoad_BindNonLoopbackRequiresTLS(t *testing.T) {
	// Non-loopback bind requires TLS to prevent cleartext token exposure.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "0.0.0.0"        # não é loopback
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por bind não-loopback sem TLS")
	}
	if !strings.Contains(err.Error(), "TLS") {
		t.Errorf("erro deve mencionar TLS, got: %v", err)
	}
}

func TestLoad_BindNonLoopbackWithTLSPasses(t *testing.T) {
	// Caso positivo: bind não-loopback COM TLS configurado deve passar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "0.0.0.0"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  tls_cert: "/etc/crias/cert.pem"
  tls_key: "/etc/crias/key.pem"
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load falhou com TLS configurado: %v", err)
	}
	if cfg.Agent.TLSCert != "/etc/crias/cert.pem" {
		t.Errorf("TLSCert = %q", cfg.Agent.TLSCert)
	}
}

func TestLoad_BindNonLoopbackMissingTLSKey(t *testing.T) {
	// Apenas tls_cert sem tls_key (ou vice-versa) deve falhar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "192.168.1.10"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  tls_cert: "/etc/crias/cert.pem"
  # tls_key ausente
server:
  service_name: "minecraft"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por tls_key ausente quando bind não é loopback")
	}
}

func TestLoad_RCONPlaceholderPassword(t *testing.T) {
	// Placeholder RCON password must be rejected.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
server:
  service_name: "minecraft"
  rcon:
    enabled: true
    host: "127.0.0.1"
    port: 25575
    password: "CHANGE_ME_RCON_PASSWORD"
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por rcon.password ainda ser placeholder")
	}
	if !strings.Contains(err.Error(), "placeholder") {
		t.Errorf("erro deve mencionar placeholder, got: %v", err)
	}
}

func TestLoad_RCONEmptyPasswordWhenEnabled(t *testing.T) {
	// rcon.enabled=true com password vazio deve falhar.
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
server:
  service_name: "minecraft"
  rcon:
    enabled: true
    host: "127.0.0.1"
    port: 25575
    password: ""
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por rcon.password vazio com rcon.enabled=true")
	}
}

func TestLoad_InvalidServiceName(t *testing.T) {
	// Invalid service_name characters must be rejected (command injection defense).
	dir := t.TempDir()
	path := filepath.Join(dir, "agent.yaml")
	err := os.WriteFile(path, []byte(`
agent:
  bind_address: "127.0.0.1"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
server:
  service_name: "minecraft; rm -rf /"   # injeção shell
`), 0644)
	if err != nil {
		t.Fatalf("escrever config: %v", err)
	}

	_, err = Load(path)
	if err == nil {
		t.Fatal("esperado erro por service_name com chars inválidos")
	}
}

func TestLoad_LoopbackAddressesAccepted(t *testing.T) {
	// Todos os endereços loopback conhecidos devem ser aceitos sem TLS.
	// Tabela: 127.0.0.1, ::1, localhost — qualquer outro exige TLS.
	for _, addr := range []string{"127.0.0.1", "::1", "localhost"} {
		t.Run(addr, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "agent.yaml")
			err := os.WriteFile(path, []byte(`
agent:
  bind_address: "`+addr+`"
  port: 8473
  auth_token: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
server:
  service_name: "minecraft"
`), 0644)
			if err != nil {
				t.Fatalf("escrever config: %v", err)
			}

			_, err = Load(path)
			if err != nil {
				t.Errorf("loopback %q não deveria falhar: %v", addr, err)
			}
		})
	}
}
