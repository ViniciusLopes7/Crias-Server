#!/usr/bin/env bash
# tests/config-parser-eq-test.sh
#
# Valida que o config-parser.sh suporta `=` em valores (item 6.4 do plano).
# Ex.: MINECRAFT_MOTD="abc=def" deve carregar como "abc=def".

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/config-parser.sh"

TMP_DIR="$(mktemp -d /tmp/crias-cfg-eq-test-XXXXXX)"
trap 'rm -rf -- "$TMP_DIR" || true' EXIT

CFG="$TMP_DIR/test.env"

cat > "$CFG" << 'EOF'
# Valores contendo = no conteúdo
MINECRAFT_MOTD="bem-vindo=key=test"
TERRARIA_MOTD="servidor do crias com sinal=ok"
SIMPLE_EQ=key=value
NESTED_QUOTES="path=/opt/server with space=true"
EOF

load_config_file "$CFG"

if [ "${MINECRAFT_MOTD:-}" != "bem-vindo=key=test" ]; then
    echo "FAIL: MINECRAFT_MOTD não preservou = no valor: '${MINECRAFT_MOTD:-}'"
    exit 1
fi

if [ "${TERRARIA_MOTD:-}" != "servidor do crias com sinal=ok" ]; then
    echo "FAIL: TERRARIA_MOTD não preservou = no valor: '${TERRARIA_MOTD:-}'"
    exit 1
fi

if [ "${SIMPLE_EQ:-}" != "key=value" ]; then
    echo "FAIL: SIMPLE_EQ não preservou = no valor: '${SIMPLE_EQ:-}'"
    exit 1
fi

if [ "${NESTED_QUOTES:-}" != "path=/opt/server with space=true" ]; then
    echo "FAIL: NESTED_QUOTES não preservou = no valor: '${NESTED_QUOTES:-}'"
    exit 1
fi

echo "OK: config-parser-eq-test"
