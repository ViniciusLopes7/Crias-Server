#!/bin/bash

# Minecraft runtime launcher with dynamic hardware-based runtime.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -f "$DEFAULT_SERVER_DIR/server.jar" ] && [ -f "/opt/minecraft-server/server.jar" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
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
SERVER_JAR="${SERVER_JAR:-server.jar}"
SERVER_PROPERTIES="${SERVER_PROPERTIES:-$SERVER_DIR/server.properties}"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
JAVA_PREFER_IPV4_STACK="${JAVA_PREFER_IPV4_STACK:-false}"

MIN_RAM="1024M"
MAX_RAM="2048M"
GC_MAX_PAUSE="200"
G1_REGION_SIZE="8M"

if [ -f "$RUNTIME_ENV" ]; then
    # shellcheck source=/dev/null
    source "$RUNTIME_ENV"
fi

normalize_mem_value() {
    local value="$1"
    local default_value="$2"

    if [[ "$value" =~ ^[0-9]+M$ ]]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

normalize_int_value() {
    local value="$1"
    local default_value="$2"

    if [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "$value"
    else
        echo "$default_value"
    fi
}

MIN_RAM="$(normalize_mem_value "$MIN_RAM" "1024M")"
MAX_RAM="$(normalize_mem_value "$MAX_RAM" "2048M")"
GC_MAX_PAUSE="$(normalize_int_value "$GC_MAX_PAUSE" "200")"

if ! [[ "$G1_REGION_SIZE" =~ ^[0-9]+M$ ]]; then
    G1_REGION_SIZE="8M"
fi

min_ram_mb=${MIN_RAM%M}
max_ram_mb=${MAX_RAM%M}

if [ "$min_ram_mb" -ge "$max_ram_mb" ]; then
    max_ram_mb=$((max_ram_mb > 1536 ? max_ram_mb : 2048))
    min_ram_mb=$((max_ram_mb * 70 / 100))
    MIN_RAM="${min_ram_mb}M"
    MAX_RAM="${max_ram_mb}M"
fi

JAVA_OPTS=""
JAVA_OPTS="$JAVA_OPTS -Xms${MIN_RAM}"
JAVA_OPTS="$JAVA_OPTS -Xmx${MAX_RAM}"
JAVA_OPTS="$JAVA_OPTS -XX:+UseG1GC"
JAVA_OPTS="$JAVA_OPTS -XX:+ParallelRefProcEnabled"
JAVA_OPTS="$JAVA_OPTS -XX:MaxGCPauseMillis=${GC_MAX_PAUSE}"
JAVA_OPTS="$JAVA_OPTS -XX:+DisableExplicitGC"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapRegionSize=${G1_REGION_SIZE}"
JAVA_OPTS="$JAVA_OPTS -XX:G1NewSizePercent=30"
JAVA_OPTS="$JAVA_OPTS -XX:G1MaxNewSizePercent=40"
JAVA_OPTS="$JAVA_OPTS -XX:G1ReservePercent=20"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapWastePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:G1MixedGCLiveThresholdPercent=90"
JAVA_OPTS="$JAVA_OPTS -XX:G1RSetUpdatingPauseTimePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:SurvivorRatio=32"
JAVA_OPTS="$JAVA_OPTS -XX:MaxTenuringThreshold=1"
JAVA_OPTS="$JAVA_OPTS -XX:InitiatingHeapOccupancyPercent=15"
JAVA_OPTS="$JAVA_OPTS -XX:+UseCompressedOops"
JAVA_OPTS="$JAVA_OPTS -XX:+UseStringDeduplication"
JAVA_OPTS="$JAVA_OPTS -XX:+PerfDisableSharedMem"
JAVA_OPTS="$JAVA_OPTS -XX:+AlwaysPreTouch"
if [ "$JAVA_PREFER_IPV4_STACK" = "true" ]; then
    JAVA_OPTS="$JAVA_OPTS -Djava.net.preferIPv4Stack=true"
fi
JAVA_OPTS="$JAVA_OPTS -Dfabric.log.disable-ansi=true"

cd "$SERVER_DIR" || exit 1

if ! command -v java >/dev/null 2>&1; then
    echo "ERRO: Java nao encontrado. Instale jdk21-openjdk."
    exit 1
fi

JAVA_VERSION_RAW="$(java -version 2>&1 | head -n 1)"
JAVA_VERSION_STRING="$(printf '%s\n' "$JAVA_VERSION_RAW" | awk -F'"' '{print $2}')"
JAVA_MAJOR_VERSION="$(printf '%s\n' "$JAVA_VERSION_STRING" | awk -F. '{ if ($1 == 1) { print $2 } else { print $1 } }')"

if ! [[ "$JAVA_MAJOR_VERSION" =~ ^[0-9]+$ ]] || [ "$JAVA_MAJOR_VERSION" -lt 21 ]; then
    echo "ERRO: Java 21+ required. Detectado: ${JAVA_VERSION_STRING:-desconhecido}"
    exit 1
fi

if [ ! -f "$SERVER_JAR" ]; then
    echo "ERRO: $SERVER_JAR nao encontrado em $SERVER_DIR"
    exit 1
fi

SERVER_PORT="$(config_read_value "$SERVER_PROPERTIES" "server-port")"
if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
    SERVER_PORT=25565
fi

if command -v ss >/dev/null 2>&1; then
    if ss -H -tln | awk -v port=":$SERVER_PORT" '$4 ~ port { found=1 } END { exit found ? 0 : 1 }'; then
        echo "ERRO: Porta $SERVER_PORT ja esta em uso. Ajuste server-port em $SERVER_PROPERTIES."
        exit 1
    fi
fi

echo "=========================================="
echo "Minecraft Server"
echo "Diretorio: $SERVER_DIR"
echo "Heap: $MIN_RAM -> $MAX_RAM"
echo "Java: $JAVA_VERSION_RAW"
echo "Porta: $SERVER_PORT"
echo "=========================================="

# Split JAVA_OPTS into an array to preserve flags with spaces and pass them safely.
read -r -a JAVA_OPTS_ARRAY <<< "$JAVA_OPTS"
# shellcheck disable=SC2068
exec java "${JAVA_OPTS_ARRAY[@]}" -jar "$SERVER_JAR" nogui
