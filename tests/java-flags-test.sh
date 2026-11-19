#!/usr/bin/env bash
# tests/java-flags-test.sh
#
# CR-01: as flags G1 experimentais (G1NewSizePercent/G1MaxNewSizePercent)
# exigem -XX:+UnlockExperimentalVMOptions ANTES delas. Sem o unlock, a JVM 21
# encerra com "VM option ... is experimental" (exit 1) e o servidor Minecraft
# nunca sobe.
#
# Parte 1 (estática): o unlock existe e precede as flags experimentais.
# Parte 2 (dinâmica, se java disponível): roda `java <flags> -version` com as
# MESMAS flags montadas pelo start-server.sh e exige exit 0.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START_SCRIPT="$ROOT_DIR/minecraft/start-server.sh"

# --- Parte 1: estática ---
if ! grep -q -- '-XX:+UnlockExperimentalVMOptions' "$START_SCRIPT"; then
    echo "FAIL: start-server.sh nao contem -XX:+UnlockExperimentalVMOptions (CR-01)"
    exit 1
fi

unlock_line=$(grep -n -- '-XX:+UnlockExperimentalVMOptions' "$START_SCRIPT" | head -1 | cut -d: -f1)
g1_line=$(grep -n -- '-XX:G1NewSizePercent=' "$START_SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$unlock_line" ] || [ -z "$g1_line" ] || [ "$unlock_line" -ge "$g1_line" ]; then
    echo "FAIL: o unlock precisa preceder G1NewSizePercent (unlock=$unlock_line, g1=$g1_line)"
    exit 1
fi
echo "OK: estatica — unlock presente e precede as flags G1 experimentais"

# --- Parte 1b (EXP-56): mapeamento versao do jogo -> Java exigido ---
# A funcao required_java_major (common.sh) e o contrato usado pelo installer
# (pacote jdk) e pelo start-server.sh (validacao de major version). MC 26.x
# exige Java 25 (anuncio oficial 26.1+); 1.20.5–1.21.x rodam com 21.
# shellcheck source=/dev/null
source "$ROOT_DIR/shared/lib/common.sh"

check_map() {
    local version="$1" expected="$2"
    local got
    got="$(required_java_major "$version")"
    if [ "$got" != "$expected" ]; then
        echo "FAIL: required_java_major($version) = $got; esperado $expected (EXP-56)"
        exit 1
    fi
}

check_map "26.3"   "25"
check_map "26.1"   "25"
check_map "26w14a" "25"
check_map "1.21.11" "21"
check_map "1.20.5" "21"
check_map "1.21.1" "21"
check_map ""       "21"
echo "OK: mapeamento versao->Java (26.x=25, 1.20.5-1.21.x=21)"

# O installer usa o pacote derivado da versao (nao mais jdk21 fixo).
if ! grep -q 'jdk${MINECRAFT_JAVA_MAJOR}-openjdk' "$ROOT_DIR/minecraft/install.sh"; then
    echo "FAIL: minecraft/install.sh nao instala o jdk derivado da versao (EXP-36)"
    exit 1
fi
if ! grep -q 'REQUIRED_JAVA_MAJOR=' "$ROOT_DIR/minecraft/start-server.sh"; then
    echo "FAIL: start-server.sh nao valida REQUIRED_JAVA_MAJOR (EXP-36)"
    exit 1
fi
echo "OK: installer/launcher usam o Java exigido pela versao do jogo"

# --- Parte 2: dinamica (so se java existir; CI Arch container nao tem java) ---
if ! command -v java >/dev/null 2>&1; then
    echo "SKIP: java nao disponivel — parte dinamica pulada (estatica ja validou)"
    exit 0
fi

java_version="$(java -version 2>&1 | head -1)"
echo "Java: $java_version"

# Reproduz o caminho de falha (sem unlock): a JVM deve recusar.
if java -Xms128M -Xmx256M -XX:+UseG1GC -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -version >/dev/null 2>&1; then
    echo "AVISO: esta JVM aceitou as flags experimentais sem unlock (pode ser versao futura); teste de controle nao conclusivo"
else
    echo "OK: controle negativo — sem unlock a JVM recusa (comportamento documentado do CR-01)"
fi

# Sequencia EXATA do start-server.sh (com unlock): deve exit 0.
if ! java -Xms128M -Xmx256M -XX:+UseG1GC -XX:+ParallelRefProcEnabled \
    -XX:MaxGCPauseMillis=200 -XX:+DisableExplicitGC \
    -XX:G1HeapRegionSize=8M -XX:+UnlockExperimentalVMOptions \
    -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 \
    -XX:G1ReservePercent=20 -XX:G1HeapWastePercent=5 \
    -XX:G1MixedGCLiveThresholdPercent=90 \
    -XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 \
    -XX:MaxTenuringThreshold=1 -XX:InitiatingHeapOccupancyPercent=15 \
    -XX:+UseCompressedOops -XX:+UseStringDeduplication \
    -XX:+PerfDisableSharedMem -XX:+AlwaysPreTouch -version >/dev/null 2>&1; then
    echo "FAIL: a JVM recusou as flags do start-server.sh MESMO com unlock (CR-01)"
    exit 1
fi
echo "OK: dinamica — sequencia completa do start-server.sh aceita pela JVM"

echo "OK: java-flags-test"
