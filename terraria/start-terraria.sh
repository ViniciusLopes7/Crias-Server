#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -x "$DEFAULT_SERVER_DIR/TerrariaServer.bin.x86_64" ] && [ ! -x "$DEFAULT_SERVER_DIR/server/LaunchUtils/ScriptCaller.sh" ] && [ -x "/opt/terraria-server/TerrariaServer.bin.x86_64" ]; then
    DEFAULT_SERVER_DIR="/opt/terraria-server"
fi

COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
if [ ! -f "$COMMON_LIB" ]; then
    COMMON_LIB="$SCRIPT_DIR/../shared/lib/common.sh"
fi

if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
fi

SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
CONFIG_FILE="${CONFIG_FILE:-$SERVER_DIR/config/serverconfig.txt}"

# tModLoader detection: se server/LaunchUtils/ScriptCaller.sh existe, usa tML.
TML_SCRIPT_CALLER="$SERVER_DIR/server/LaunchUtils/ScriptCaller.sh"
USE_TMODLOADER="false"
if [ -x "$TML_SCRIPT_CALLER" ]; then
    USE_TMODLOADER="true"
else
    SERVER_BIN="${SERVER_BIN:-$SERVER_DIR/TerrariaServer.bin.x86_64}"
fi

cd "$SERVER_DIR" || exit 1

# Validações específicas por modo.
if [ "$USE_TMODLOADER" = "true" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "ERRO: Arquivo de configuracao nao encontrado: $CONFIG_FILE"
        exit 1
    fi
else
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
        # ldd retorna nao-zero para binarios estaticos tambem. Mudamos para
        # aviso (nao abortar) para nao quebrar em binarios estaticos legitimos.
        if ! ldd_output="$(ldd "$SERVER_BIN" 2>&1)"; then
            echo "AVISO: ldd reportou possivel problema com dependencias do binario:"
            echo "  $ldd_output"
            echo "AVISO: Se o binario for estatico, isso e normal. Se for dinamico, verifique:"
            echo "  - multilib habilitado em /etc/pacman.conf (se 32-bit)"
            echo "  - bibliotecas necessarias instaladas (lib32-glibc, etc.)"
        fi
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERRO: Arquivo de configuracao nao encontrado: $CONFIG_FILE"
    exit 1
fi

for key in worldpath port maxplayers; do
    if [ -z "$(config_read_value "$CONFIG_FILE" "$key")" ]; then
        echo "ERRO: Campo obrigatorio '${key}' ausente em $CONFIG_FILE"
        exit 1
    fi
done

WORLD_PATH="$(config_read_value "$CONFIG_FILE" "worldpath")"
if [ -n "$WORLD_PATH" ]; then
    WORLD_PATH_DIR="$(dirname "$WORLD_PATH")"
    if [ ! -w "$WORLD_PATH_DIR" ]; then
        echo "ERRO: Diretorio de worldpath nao e gravavel: $WORLD_PATH_DIR"
        exit 1
    fi
fi

SERVER_PORT="$(config_read_value "$CONFIG_FILE" "port")"
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
if [ "$USE_TMODLOADER" = "true" ]; then
    echo "tModLoader Dedicated Server (Terraria com mods)"
    echo "ScriptCaller: $TML_SCRIPT_CALLER"
else
    echo "Terraria Dedicated Server (vanilla)"
    echo "Binario: $SERVER_BIN"
fi
echo "Diretorio: $SERVER_DIR"
echo "Config: $CONFIG_FILE"
echo "Porta: $SERVER_PORT"
echo "=========================================="

if [ "$USE_TMODLOADER" = "true" ]; then
    # tModLoader: ScriptCaller.sh faz cd automatico para o diretorio dele.
    # -tmlsavedirectory aponta para $SERVER_DIR (onde Mods/ e Worlds/ ficam).
    # -steamworkshopfolder aponta para onde SteamCMD baixou os mods.
    cd "$SERVER_DIR/server" || exit 1
    exec ./LaunchUtils/ScriptCaller.sh -server \
        -config "$CONFIG_FILE" \
        -steamworkshopfolder "$SERVER_DIR/steamapps/workshop" \
        -tmlsavedirectory "$SERVER_DIR"
else
    exec "$SERVER_BIN" -config "$CONFIG_FILE"
fi
