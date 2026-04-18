#!/bin/bash

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

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERRO: Arquivo de configuracao nao encontrado: $CONFIG_FILE"
    exit 1
fi

echo "=========================================="
echo "Terraria Dedicated Server"
echo "Diretorio: $SERVER_DIR"
echo "Config: $CONFIG_FILE"
echo "=========================================="

exec "$SERVER_BIN" -config "$CONFIG_FILE"
