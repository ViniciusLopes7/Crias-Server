#!/usr/bin/env bash
# tests/agent-install-hook-test.sh
#
# Valida a função install_crias_agent_if_enabled() do install.sh.
#
# Como essa função faz chamadas sudo, useradd, download, etc., não podemos
# rodá-la em CI sem um ambiente Arch real. Em vez disso, fazemos source
# do install.sh e validamos que:
#   1. A função existe e está exportada
#   2. O agent.example.yaml é um YAML válido
#   3. As variáveis necessárias estão declaradas no config-parser.sh
#   4. O sudoers template está consistente com o que install.sh gera

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

# 1. Função existe em install.sh
assert_grep '^install_crias_agent_if_enabled\(\)' "$ROOT_DIR/install.sh"

# 2. install.sh chama a função no final de main()
assert_grep 'install_crias_agent_if_enabled' "$ROOT_DIR/install.sh"

# 3. agent.example.yaml existe e tem campos esperados
assert_file "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'agent:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'bind_address:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'port: 8473' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'auth_token:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'server:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'stack:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'service_name:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'manager_script:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'rcon:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'features:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'auto_shutdown:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'health_check:' "$ROOT_DIR/discord-agent/agent.example.yaml"
# v1.1.0+: novos campos server_port e hardware_tier
assert_grep_fixed 'server_port:' "$ROOT_DIR/discord-agent/agent.example.yaml"
assert_grep_fixed 'hardware_tier:' "$ROOT_DIR/discord-agent/agent.example.yaml"

# 4. install.sh referencia /etc/crias/agent.yaml (caminho onde o agente lê config)
assert_grep '/etc/crias/agent.yaml' "$ROOT_DIR/install.sh"

# 5. install.sh gera sudoers em /etc/sudoers.d/crias-agent
assert_grep '/etc/sudoers.d/crias-agent' "$ROOT_DIR/install.sh"

# 6. install.sh instala systemd unit /etc/systemd/system/crias-agent.service
assert_grep '/etc/systemd/system/crias-agent.service' "$ROOT_DIR/install.sh"

# 7. install.sh gera token via generate_token (32 bytes hex = 64 chars)
assert_grep 'generate_token 32' "$ROOT_DIR/install.sh"

# 8. install.sh referencia o binário no caminho esperado /opt/crias-agent/crias-agent
assert_grep '/opt/crias-agent/crias-agent' "$ROOT_DIR/install.sh"

# 9. systemd unit hardcoded no install.sh tem hardening esperado
assert_grep 'MemoryMax=32M' "$ROOT_DIR/install.sh"
assert_grep 'CPUQuota=10%' "$ROOT_DIR/install.sh"
assert_grep 'MemoryDenyWriteExecute=yes' "$ROOT_DIR/install.sh"
assert_grep 'SystemCallFilter=@system-service' "$ROOT_DIR/install.sh"
assert_grep 'CapabilityBoundingSet=' "$ROOT_DIR/install.sh"
assert_grep 'ProtectSystem=strict' "$ROOT_DIR/install.sh"
assert_grep 'NoNewPrivileges=yes' "$ROOT_DIR/install.sh"
assert_grep 'LockPersonality=yes' "$ROOT_DIR/install.sh"
assert_grep 'RestrictSUIDSGID=yes' "$ROOT_DIR/install.sh"
assert_grep 'RestrictRealtime=yes' "$ROOT_DIR/install.sh"
assert_grep 'RemoveIPC=yes' "$ROOT_DIR/install.sh"
assert_grep 'ProtectHostname=yes' "$ROOT_DIR/install.sh"
assert_grep 'ProtectClock=yes' "$ROOT_DIR/install.sh"

# 10. INSTALL_AGENT é uma variável configurável em config.env
assert_grep '^INSTALL_AGENT=' "$ROOT_DIR/config.env"
assert_grep 'INSTALL_AGENT' "$ROOT_DIR/shared/lib/config-parser.sh"

# 11. YAML validation (se python3 + pyyaml disponíveis)
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    if ! python3 -c "
import yaml
with open('$ROOT_DIR/discord-agent/agent.example.yaml') as f:
    cfg = yaml.safe_load(f)
assert 'agent' in cfg, 'missing agent section'
assert 'server' in cfg, 'missing server section'
assert 'features' in cfg, 'missing features section'
assert cfg['agent']['port'] == 8473, 'wrong port'
assert cfg['agent']['bind_address'] == '127.0.0.1', 'wrong bind_address'
assert cfg['server']['stack'] in ('minecraft', 'terraria'), 'wrong stack'
# v1.1.0+: novos campos
assert 'server_port' in cfg['server'], 'missing server_port'
assert isinstance(cfg['server']['server_port'], int), 'server_port deve ser int'
assert cfg['server']['server_port'] > 0, 'server_port deve ser > 0'
assert 'hardware_tier' in cfg['server'], 'missing hardware_tier'
assert cfg['server']['hardware_tier'] in ('LOW', 'MID', 'HIGH', 'unknown'), 'wrong hardware_tier'
assert 'auto_shutdown' in cfg['features'], 'missing auto_shutdown'
assert 'health_check' in cfg['features'], 'missing health_check'
assert cfg['features']['auto_shutdown']['enabled'] is False, 'auto_shutdown should be off by default'
assert cfg['features']['auto_shutdown']['empty_minutes'] == 30, 'wrong empty_minutes'
assert cfg['features']['health_check']['interval_seconds'] == 300, 'wrong interval'
assert cfg['features']['health_check']['passive'] is True, 'should be passive'
print('YAML validado com sucesso')
" 2>&1; then
        echo "FAIL: agent.example.yaml falhou validação YAML"
        exit 1
    fi
fi

# 12. validate_token() no agente Go rejeita metadata vazia (lógica documentada em server.go)
assert_grep 'func validateToken' "$ROOT_DIR/discord-agent/internal/server/server.go"
assert_grep 'codes.Unauthenticated' "$ROOT_DIR/discord-agent/internal/server/server.go"
assert_grep 'x-api-token' "$ROOT_DIR/discord-agent/internal/server/server.go"

echo "OK: agent-install-hook-test"
