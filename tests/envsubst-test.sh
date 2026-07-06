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
# TST-007: stderr não é mais silenciado (2>/dev/null removido). Warnings/errors
# do systemd-analyze agora fazem o teste falhar (não são mais tratados como
# "normais em container"). A única exceção é quando o systemd-analyze sequer
# consegue rodar em container sem /sys/fs/cgroup montado — nesse caso, fazemos
# SKIP explícito em vez de swallow silencioso.
if command -v systemd-analyze >/dev/null 2>&1; then
    TMP_UNIT="/tmp/crias-minecraft-test.service"
    echo "$OUTPUT" > "$TMP_UNIT"
    verify_log="$(mktemp /tmp/crias-systemd-analyze.XXXXXX.log)"
    if systemd-analyze verify "$TMP_UNIT" > "$verify_log" 2>&1; then
        # systemd-analyze retorna 0 mesmo com warnings — varremos o log em
        # busca de palavras-chave de erro/warning para decidir.
        if grep -Eiq 'error|warning|fail' "$verify_log"; then
            echo "FAIL: systemd-analyze verify reportou problemas em $TMP_UNIT:" >&2
            cat "$verify_log" >&2
            rm -f "$TMP_UNIT" "$verify_log"
            exit 1
        fi
        echo "OK: systemd-analyze verify passou sem warnings"
    else
        # Exit code != 0 significa erro real (unit inválida).
        echo "FAIL: systemd-analyze verify falhou (exit != 0) em $TMP_UNIT:" >&2
        cat "$verify_log" >&2
        rm -f "$TMP_UNIT" "$verify_log"
        exit 1
    fi
    rm -f "$TMP_UNIT" "$verify_log"
fi

echo "OK: envsubst-test"
