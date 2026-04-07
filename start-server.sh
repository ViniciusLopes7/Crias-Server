#!/bin/bash

# ============================================
# Minecraft Server Start Script
# Otimizado para: i3-6006U | 4GB RAM | HDD
# Modpack: Adrenaline 1.21.11
# ============================================

# === CONFIGURAÇÕES ===
SERVER_DIR="/opt/minecraft-server"
SERVER_JAR="server.jar"
MIN_RAM="2560M"
MAX_RAM="2560M"

# === FLAGS JVM OTIMIZADAS PARA HARDWARE LIMITADO ===
# Baseado em Aikar's Flags + otimizações para G1GC com pouca RAM

JAVA_OPTS=""

# Memory Settings - Alocação dinâmica
JAVA_OPTS="$JAVA_OPTS -Xms${MIN_RAM}"
JAVA_OPTS="$JAVA_OPTS -Xmx${MAX_RAM}"

# Garbage Collector G1 (melhor para <4GB)
JAVA_OPTS="$JAVA_OPTS -XX:+UseG1GC"
JAVA_OPTS="$JAVA_OPTS -XX:+ParallelRefProcEnabled"
JAVA_OPTS="$JAVA_OPTS -XX:MaxGCPauseMillis=200"
JAVA_OPTS="$JAVA_OPTS -XX:+UnlockExperimentalVMOptions"

# Desabilitar GC explícito (evita pausas)
JAVA_OPTS="$JAVA_OPTS -XX:+DisableExplicitGC"

# Configurações G1GC otimizadas (Aikar + Ajustes para 2.5GB)
JAVA_OPTS="$JAVA_OPTS -XX:G1NewSizePercent=30"
JAVA_OPTS="$JAVA_OPTS -XX:G1MaxNewSizePercent=40"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapRegionSize=8M"
JAVA_OPTS="$JAVA_OPTS -XX:G1ReservePercent=20"
JAVA_OPTS="$JAVA_OPTS -XX:G1HeapWastePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:G1MixedGCLiveThresholdPercent=90"
JAVA_OPTS="$JAVA_OPTS -XX:G1RSetUpdatingPauseTimePercent=5"
JAVA_OPTS="$JAVA_OPTS -XX:SurvivorRatio=32"
JAVA_OPTS="$JAVA_OPTS -XX:MaxTenuringThreshold=1"
JAVA_OPTS="$JAVA_OPTS -XX:InitiatingHeapOccupancyPercent=15"

# Otimizações para pouca memória
JAVA_OPTS="$JAVA_OPTS -XX:+UseCompressedOops"
JAVA_OPTS="$JAVA_OPTS -XX:+UseStringDeduplication"

# Reduzir overhead de logging
JAVA_OPTS="$JAVA_OPTS -XX:+PerfDisableSharedMem"

# Otimizações de rede
JAVA_OPTS="$JAVA_OPTS -Djava.net.preferIPv4Stack=true"

# Fabric/Minecraft específico
JAVA_OPTS="$JAVA_OPTS -Dfabric.log.disable-ansi=true"
JAVA_OPTS="$JAVA_OPTS -Dlog4j2.formatMsgNoLookups=true"

# === INICIAR SERVIDOR ===
cd "$SERVER_DIR" || exit 1

# Verificar se há RAM suficiente disponível
AVAILABLE_RAM=$(free -m | awk 'NR==2{print $7}')
if [ "$AVAILABLE_RAM" -lt 2560 ]; then
    echo "=========================================="
    echo "AVISO: Pouca RAM disponível ($AVAILABLE_RAM MB)"
    echo "O servidor pode travar ou ter problemas de performance."
    echo "Considere fechar outros programas antes de continuar."
    echo "=========================================="
    sleep 5
fi

# Verificar se Java está instalado
if ! command -v java &> /dev/null; then
    echo "ERRO: Java não encontrado!"
    echo "Instale o Java 21: sudo pacman -S jdk21-openjdk"
    exit 1
fi

# Verificar versão do Java
JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
if [ "$JAVA_VERSION" != "21" ]; then
    echo "AVISO: Java $JAVA_VERSION detectado. Recomendado: Java 21"
fi

# Verificar se server.jar existe
if [ ! -f "$SERVER_JAR" ]; then
    echo "ERRO: $SERVER_JAR não encontrado!"
    echo "Execute o mrpack-install primeiro."
    exit 1
fi

echo "=========================================="
echo "  Minecraft Server - Adrenaline"
echo "=========================================="
echo "RAM Alocada: $MIN_RAM - $MAX_RAM"
echo "Diretório: $SERVER_DIR"
echo "Java: $(java -version 2>&1 | head -1)"
echo "=========================================="
echo "Iniciando servidor..."
echo ""

# Iniciar servidor
# shellcheck disable=SC2086  # JAVA_OPTS is intentionally word-split into multiple JVM flags
exec java $JAVA_OPTS -jar "$SERVER_JAR" nogui
