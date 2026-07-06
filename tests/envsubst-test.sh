#!/usr/bin/env bash
# tests/envsubst-test.sh
#
# Valida que o template .service pode ser processado por envsubst sem erros
# e produz a unit systemd esperada com variáveis substituídas corretamente.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

if ! command -v envsubst >/dev/null 2>&1; then
    echo "SKIP: envsubst não disponível neste ambiente (gettext não instalado)"
    exit 0
fi

# 1. Template do Minecraft
# envsubst lê variáveis do AMBIENTE (não do shell), então precisamos exportar.
export SERVER_USER="minecraft"
export SERVER_DIR="/opt/minecraft-server"
export MEMORY_MAX_MB="4096"
export SERVICE_NAME="minecraft"

OUTPUT=$(envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
    < "$ROOT_DIR/minecraft/minecraft.service")

# Verifica que as variáveis foram substituídas
if ! echo "$OUTPUT" | grep -q '^User=minecraft$'; then
    echo "FAIL: User não substituído no template do Minecraft"
    echo "$OUTPUT" | head -20
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^WorkingDirectory=/opt/minecraft-server$'; then
    echo "FAIL: WorkingDirectory não substituído no template do Minecraft"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^MemoryMax=4096M$'; then
    echo "FAIL: MemoryMax não substituído no template do Minecraft"
    exit 1
fi

# Verifica que NÃO restaram placeholders __VAR__
if echo "$OUTPUT" | grep -q '__'; then
    echo "FAIL: Template do Minecraft contém placeholders não substituídos"
    echo "$OUTPUT"
    exit 1
fi

# 2. Template do Terraria
export SERVER_USER="terraria"
export SERVER_DIR="/opt/terraria-server"
export MEMORY_MAX_MB="2048"
export SERVICE_NAME="terraria"

OUTPUT=$(envsubst '${SERVER_USER} ${SERVER_DIR} ${MEMORY_MAX_MB} ${SERVICE_NAME}' \
    < "$ROOT_DIR/terraria/terraria.service")

if ! echo "$OUTPUT" | grep -q '^User=terraria$'; then
    echo "FAIL: User não substituído no template do Terraria"
    exit 1
fi

if ! echo "$OUTPUT" | grep -q '^MemoryMax=2048M$'; then
    echo "FAIL: MemoryMax não substituído no template do Terraria"
    exit 1
fi

# 3. Validação com systemd-analyze verify (se disponível).
# Filtra saída para só verificar erros de SINTAXE do nosso unit file,
# ignorando erros de ambiente (units do sistema, paths inexistentes em CI).
if command -v systemd-analyze >/dev/null 2>&1; then
    TMP_UNIT="/tmp/crias-minecraft-test.service"
    echo "$OUTPUT" > "$TMP_UNIT"
    verify_log="$(mktemp /tmp/crias-systemd-analyze.XXXXXX.log)"
    systemd-analyze verify "$TMP_UNIT" > "$verify_log" 2>&1 || true

    # Filtra: só linhas que mencionam NOSSO unit file E são erros de sintaxe.
    # Ignora erros de units do sistema (netplan, snapd) e paths inexistentes.
    our_errors="$(grep -E "$(basename "$TMP_UNIT")" "$verify_log" 2>/dev/null \
        | grep -viE 'not executable|No such file|Command .* is not' \
        | grep -iE 'error|fail|invalid|unknown|syntax' || true)"

    if [ -n "$our_errors" ]; then
        echo "FAIL: systemd-analyze verify encontrou erros de sintaxe em $TMP_UNIT:" >&2
        echo "$our_errors" >&2
        rm -f "$TMP_UNIT" "$verify_log"
        exit 1
    fi
    echo "OK: systemd-analyze verify passou (sem erros de sintaxe no nosso unit)"
    rm -f "$TMP_UNIT" "$verify_log"
fi

echo "OK: envsubst-test"
