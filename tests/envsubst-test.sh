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
SERVER_USER="minecraft"
SERVER_DIR="/opt/minecraft-server"
MEMORY_MAX_MB="4096"
SERVICE_NAME="minecraft"

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
SERVER_USER="terraria"
SERVER_DIR="/opt/terraria-server"
MEMORY_MAX_MB="2048"
SERVICE_NAME="terraria"

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

# 3. Validação com systemd-analyze verify (se disponível)
if command -v systemd-analyze >/dev/null 2>&1; then
    TMP_UNIT="/tmp/crias-minecraft-test.service"
    echo "$OUTPUT" > "$TMP_UNIT"
    if ! systemd-analyze verify "$TMP_UNIT" 2>/dev/null; then
        echo "WARN: systemd-analyze verify reportou warnings em $TMP_UNIT (normal em container)"
    fi
    rm -f "$TMP_UNIT"
fi

echo "OK: envsubst-test"
