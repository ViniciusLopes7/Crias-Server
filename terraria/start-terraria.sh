#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -x "$DEFAULT_SERVER_DIR/TerrariaServer.bin.x86_64" ] && [ -x "/opt/terraria-server/TerrariaServer.bin.x86_64" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
SERVER_BIN="${SERVER_BIN:-$SERVER_DIR/TerrariaServer.bin.x86_64}"
CONFIG_FILE="${CONFIG_FILE:-$SERVER_DIR/config/serverconfig.txt}"

cd "$SERVER_DIR" || exit 1

if [ ! -x "$SERVER_BIN" ]; then
    echo "ERRO: Binario do Terraria nao encontrado: $SERVER_BIN"
    exit 1
fi

if command -v file >/dev/null 2>&1; then
    if ! file "$SERVER_BIN" | grep -qi "x86-64"; then
        echo "AVISO: Binario pode nao ser x86_64. Verifique compatibilidade da arquitetura."
    fi
fi

if command -v ldd >/dev/null 2>&1; then
    if ! ldd "$SERVER_BIN" >/dev/null 2>&1; then
        echo "ERRO: Dependencias do binario nao satisfeitas. Verifique multilib/bibliotecas necessarias."
        exit 1
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERRO: Arquivo de configuracao nao encontrado: $CONFIG_FILE"
    exit 1
fi

for key in worldpath port maxplayers; do
    if ! grep -qE "^${key}=" "$CONFIG_FILE"; then
        echo "ERRO: Campo obrigatorio '${key}' ausente em $CONFIG_FILE"
        exit 1
    fi
done

WORLD_PATH="$(grep -E '^worldpath=' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- || true)"
if [ -n "$WORLD_PATH" ]; then
    WORLD_PATH_DIR="$(dirname "$WORLD_PATH")"
    if [ ! -w "$WORLD_PATH_DIR" ]; then
        echo "ERRO: Diretorio de worldpath nao e gravavel: $WORLD_PATH_DIR"
        exit 1
    fi
fi

SERVER_PORT="$(grep -E '^port=' "$CONFIG_FILE" 2>/dev/null | tail -n 1 | cut -d'=' -f2- || true)"
if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
    SERVER_PORT=7777
fi

if command -v ss >/dev/null 2>&1; then
    if ss -H -tln | awk -v port=":$SERVER_PORT" '$4 ~ port { found=1 } END { exit found ? 0 : 1 }'; then
        echo "ERRO: Porta $SERVER_PORT ja esta em uso. Ajuste port em $CONFIG_FILE."
        exit 1
    fi
fi

echo "=========================================="
echo "Terraria Dedicated Server"
echo "Diretorio: $SERVER_DIR"
echo "Config: $CONFIG_FILE"
echo "Porta: $SERVER_PORT"
echo "=========================================="

exec "$SERVER_BIN" -config "$CONFIG_FILE"
