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
