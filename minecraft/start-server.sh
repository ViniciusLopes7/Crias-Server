#!/bin/bash
# minecraft/start-server.sh
#
# Minecraft runtime launcher with dynamic tuning from runtime.env.
# JAVA_OPTS built as native array to preserve flags with spaces.

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
NATIVE_OVERHEAD_MB="0"
GC_MAX_PAUSE="200"
G1_REGION_SIZE="8M"

if [ -f "$RUNTIME_ENV" ]; then
    # shellcheck source=/dev/null
    source "$RUNTIME_ENV"
fi

normalize_mem_value() {
    local value="$1"
    local default_value="$2"

    if [[ "$value" =~ ^[1-9][0-9]*M$ ]]; then
        echo "$value"
    else
        echo "ERRO: valor de memoria invalido: $value (esperado numero positivo em M)." >&2
        return 1
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
if ! [[ "$NATIVE_OVERHEAD_MB" =~ ^[0-9]{1,6}$ ]]; then
    echo "ERRO: NATIVE_OVERHEAD_MB invalido no runtime.env: $NATIVE_OVERHEAD_MB" >&2
    exit 1
fi

# Só corrige se min > max (config inválida). Se min == max (cenario válido
# quando o usuario quer -Xms==-Xmx, recomendado para producao), mantém.
if [ "$min_ram_mb" -gt "$max_ram_mb" ]; then
    echo "ERRO: MIN_RAM=$MIN_RAM excede MAX_RAM=$MAX_RAM; ajuste runtime.env." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# JAVA_OPTS as native array. Replaces concatenated string + read -a split
# which broke on paths with spaces.
# ---------------------------------------------------------------------------
JAVA_OPTS=()
JAVA_OPTS+=("-Xms${MIN_RAM}")
JAVA_OPTS+=("-Xmx${MAX_RAM}")
JAVA_OPTS+=("-XX:+UseG1GC")
JAVA_OPTS+=("-XX:+ParallelRefProcEnabled")
JAVA_OPTS+=("-XX:MaxGCPauseMillis=${GC_MAX_PAUSE}")
JAVA_OPTS+=("-XX:+DisableExplicitGC")
JAVA_OPTS+=("-XX:G1HeapRegionSize=${G1_REGION_SIZE}")
# G1NewSizePercent/G1MaxNewSizePercent são flags EXPERIMENTAIS: sem o unlock
# antes delas a JVM 21 encerra com "VM option ... is experimental" (exit 1) e
# o servidor nunca sobe. UnlockExperimentalVMOptions é aceito desde o JDK 8 e
# inofensivo quando as flags virarem product flags no futuro.
JAVA_OPTS+=("-XX:+UnlockExperimentalVMOptions")
JAVA_OPTS+=("-XX:G1NewSizePercent=30")
JAVA_OPTS+=("-XX:G1MaxNewSizePercent=40")
JAVA_OPTS+=("-XX:G1ReservePercent=20")
JAVA_OPTS+=("-XX:G1HeapWastePercent=5")
JAVA_OPTS+=("-XX:G1MixedGCLiveThresholdPercent=90")
JAVA_OPTS+=("-XX:G1RSetUpdatingPauseTimePercent=5")
JAVA_OPTS+=("-XX:MaxTenuringThreshold=1")
JAVA_OPTS+=("-XX:InitiatingHeapOccupancyPercent=15")
JAVA_OPTS+=("-XX:+UseCompressedOops")
JAVA_OPTS+=("-XX:+UseStringDeduplication")
JAVA_OPTS+=("-XX:+PerfDisableSharedMem")
# Nao usar AlwaysPreTouch por padrao: Forge pesado pode pre-alocar muita
# memoria antes de ficar disponivel, aumentando pressao de startup.
if [ "$JAVA_PREFER_IPV4_STACK" = "true" ]; then
    JAVA_OPTS+=("-Djava.net.preferIPv4Stack=true")
fi
# -Dfabric.log.disable-ansi é propriedade específica do Fabric Loader (prefixo "fabric.").
# Quilt é compatível com Fabric, então também aplica. Para forge/neoforge/vanilla,
# a flag seria no-op (JVM seta mas server não lê), mas evitamos por correção semântica.
# Default "fabric" preserva backward-compat com runtime.env antigo sem MINECRAFT_LOADER.
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
if [ "$MINECRAFT_LOADER" = "fabric" ] || [ "$MINECRAFT_LOADER" = "quilt" ]; then
    JAVA_OPTS+=("-Dfabric.log.disable-ansi=true")
fi

cd "$SERVER_DIR" || exit 1

# (EXP-36) Binario java configuravel (caminho absoluto pelo runtime.env se
# o host tiver multiplos JDKs) e requisito minimo DERIVADO DA VERSAO DO JOGO:
# MC 26.x exige Java 25 (anuncio oficial 26.1+); 1.20.5-1.21.x exige 21.
REQUIRED_JAVA_MAJOR="$(required_java_major "${MINECRAFT_VERSION:-1.21}")"
if [ -z "${JAVA_BIN:-}" ]; then
    if [ -x "/usr/lib/jvm/java-${REQUIRED_JAVA_MAJOR}-openjdk/bin/java" ]; then
        JAVA_BIN="/usr/lib/jvm/java-${REQUIRED_JAVA_MAJOR}-openjdk/bin/java"
    else
        echo "ERRO: JDK $REQUIRED_JAVA_MAJOR nao encontrado em /usr/lib/jvm. Instale jdk${REQUIRED_JAVA_MAJOR}-openjdk ou configure JAVA_BIN explicitamente." >&2
        exit 1
    fi
fi
if ! command -v "$JAVA_BIN" >/dev/null 2>&1; then
    echo "ERRO: Java nao encontrado ($JAVA_BIN). Instale o jdk-openjdk da versao exigida."
    exit 1
fi

JAVA_VERSION_RAW="$("$JAVA_BIN" -version 2>&1 | head -n 1)"
JAVA_VERSION_STRING="$(printf '%s\n' "$JAVA_VERSION_RAW" | awk -F'"' '{print $2}')"
JAVA_MAJOR_VERSION="$(printf '%s\n' "$JAVA_VERSION_STRING" | awk -F. '{ if ($1 == 1) { print $2 } else { print $1 } }')"

if ! [[ "$JAVA_MAJOR_VERSION" =~ ^[0-9]+$ ]] || [ "$JAVA_MAJOR_VERSION" -lt "$REQUIRED_JAVA_MAJOR" ]; then
    echo "ERRO: Java ${REQUIRED_JAVA_MAJOR}+ exigido para Minecraft ${MINECRAFT_VERSION:-desconhecida}. Detectado: ${JAVA_VERSION_STRING:-desconhecido}"
    exit 1
fi

# Modern Forge/NeoForge install a platform-specific argument file, not a
# standalone server.jar. Reject ambiguous installations rather than guessing.
LOADER_ARGS=""
if [ "$MINECRAFT_LOADER" = forge ] || [ "$MINECRAFT_LOADER" = neoforge ]; then
    mapfile -t loader_arg_files < <(find libraries/net -type f -name unix_args.txt \
         -path "*/${MINECRAFT_LOADER}/*/unix_args.txt" 2>/dev/null | sort)
    if [ "${#loader_arg_files[@]}" -gt 1 ]; then
        echo "ERRO: multiplos unix_args.txt; remova instalacoes antigas do loader."
        exit 1
    fi
    if [ "${#loader_arg_files[@]}" -eq 1 ]; then
        LOADER_ARGS="${loader_arg_files[0]}"
    fi
fi
if [ -z "$LOADER_ARGS" ] && [ ! -f "$SERVER_JAR" ]; then
    echo "ERRO: $SERVER_JAR ou argumentos do loader nao encontrados em $SERVER_DIR"
    exit 1
fi

SERVER_PORT="$(config_read_value "$SERVER_PROPERTIES" "server-port")"
if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
    SERVER_PORT=25565
fi

# (CR-32) Igualdade exata de porta (2556 nao conflita mais com 25565).
if port_is_listening "$SERVER_PORT"; then
    echo "ERRO: Porta $SERVER_PORT ja esta em uso. Ajuste server-port em $SERVER_PROPERTIES."
    exit 1
fi

echo "=========================================="
echo "Minecraft Server"
echo "Diretorio: $SERVER_DIR"
echo "Heap: $MIN_RAM -> $MAX_RAM"
echo "Java: $JAVA_VERSION_RAW"
echo "Porta: $SERVER_PORT"
echo "=========================================="

# Valide o limite do cgroup efetivo ANTES do JVM tentar alocar o heap.
# Memoria nativa minima acompanha o tuning; envs anteriores sao tratados
# como modo compatibilidade (Xmx precisa ser estritamente menor que a cota).
CGROUP_MEMORY_LIB="$SCRIPT_DIR/.shared/hardware-profile.sh"
if [ ! -f "$CGROUP_MEMORY_LIB" ]; then
    CGROUP_MEMORY_LIB="$SCRIPT_DIR/../shared/lib/hardware-profile.sh"
fi
if [ -f "$CGROUP_MEMORY_LIB" ]; then
    # shellcheck source=/dev/null
    source "$CGROUP_MEMORY_LIB"
    effective_limit_mb="$(cgroup_v2_effective_memory_mb 2>/dev/null || true)"
    if [[ "$effective_limit_mb" =~ ^[0-9]+$ ]] && [ "$effective_limit_mb" -gt 0 ]; then
        if [ "$((max_ram_mb + NATIVE_OVERHEAD_MB))" -gt "$effective_limit_mb" ] || [ "$max_ram_mb" -ge "$effective_limit_mb" ]; then
            echo "ERRO: Xmx ${max_ram_mb}MB + overhead ${NATIVE_OVERHEAD_MB}MB excede MemoryMax efetivo ${effective_limit_mb}MB. Corrija runtime.env e o limite systemd; Java NAO sera iniciado." >&2
            exit 1
        fi
        echo "Limite efetivo do cgroup: ${effective_limit_mb}MB (heap ${max_ram_mb}MB, overhead planejado ${NATIVE_OVERHEAD_MB}MB)"
    fi
fi

# Run java with native array (preserves flags with spaces).
# (EXP-38) Forge 1.17+ e NeoForge EXIGEM os JVM args gerados pelo instalador
# (user_jvm_args.txt) — `java -jar server.jar` puro nao inicia esses loaders.
# Os args do arquivo vem DEPOIS dos nossos: java usa a ultima ocorrencia,
# entao um Xmx no @file (se o usuario o configurou) prevalece sobre o nosso.
# Limites de memoria escondidos num argfile Forge sobrescrevem -Xmx do
# runtime.env e invalidam o calculo do MemoryMax. Recuse o conflito.
LAUNCH_ARGS=()
if { [ "$MINECRAFT_LOADER" = "forge" ] || [ "$MINECRAFT_LOADER" = "neoforge" ]; } \
    && [ -f "$SERVER_DIR/user_jvm_args.txt" ]; then
    if grep -Ev '^[[:space:]]*(#|$)' "$SERVER_DIR/user_jvm_args.txt" | \
        grep -Eq '(^|[[:space:]])-(Xmx|Xms|XX:(MaxRAM|InitialRAM|MaxRAMPercentage|InitialRAMPercentage))'; then
        echo "ERRO: user_jvm_args.txt contem Xmx/Xms/MaxRAM. Defina heap somente em runtime.env para respeitar MemoryMax." >&2
        exit 1
    fi
    LAUNCH_ARGS+=("@user_jvm_args.txt")
    echo "Loader $MINECRAFT_LOADER: usando @user_jvm_args.txt"
fi

if [ -n "$LOADER_ARGS" ]; then
    exec "$JAVA_BIN" "${JAVA_OPTS[@]}" "${LAUNCH_ARGS[@]}" "@$LOADER_ARGS" nogui
fi
exec "$JAVA_BIN" "${JAVA_OPTS[@]}" "${LAUNCH_ARGS[@]}" -jar "$SERVER_JAR" nogui
