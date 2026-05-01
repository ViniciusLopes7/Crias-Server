#!/bin/bash

# Minecraft tuning helpers based on detected hardware profile.

clamp_value() {
    local value="$1"
    local min="$2"
    local max="$3"

    # Ensure numeric
    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        echo "$min"
        return 0
    fi

    if [ "$value" -lt "$min" ]; then
        echo "$min"
        return 0
    fi

    if [ "$value" -gt "$max" ]; then
        echo "$max"
        return 0
    fi

    echo "$value"
}

compute_minecraft_tuning() {
    local total_ram_mb="$1"
    local cpu_cores="$2"
    local disk_type="$3"
    local tier="$4"

    local reserve_mb
    local xmx_mb
    local xms_mb
    local service_memory_mb

    case "$tier" in
        LOW)
            reserve_mb=1000
            MC_VIEW_DISTANCE=4
            MC_SIMULATION_DISTANCE=3
            MC_MAX_PLAYERS=6
            MC_GC_MAX_PAUSE=250
            MC_ENTITY_BROADCAST_RANGE=60
            ;;
        MID)
            reserve_mb=1800
            MC_VIEW_DISTANCE=8
            MC_SIMULATION_DISTANCE=5
            MC_MAX_PLAYERS=16
            MC_GC_MAX_PAUSE=200
            MC_ENTITY_BROADCAST_RANGE=80
            ;;
        HIGH)
            reserve_mb=3072
            MC_VIEW_DISTANCE=12
            MC_SIMULATION_DISTANCE=8
            MC_MAX_PLAYERS=40
            MC_GC_MAX_PAUSE=150
            MC_ENTITY_BROADCAST_RANGE=100
            ;;
        *)
            reserve_mb=1800
            MC_VIEW_DISTANCE=8
            MC_SIMULATION_DISTANCE=5
            MC_MAX_PLAYERS=16
            MC_GC_MAX_PAUSE=200
            MC_ENTITY_BROADCAST_RANGE=80
            ;;
    esac

    # Normalize numeric inputs to avoid "integer expected" errors in comparisons
    total_ram_mb="${total_ram_mb:-0}"
    cpu_cores="${cpu_cores:-0}"
    if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]]; then
        total_ram_mb=0
    fi
    if ! [[ "$cpu_cores" =~ ^[0-9]+$ ]]; then
        cpu_cores=0
    fi

    xmx_mb=$((total_ram_mb - reserve_mb))
    xmx_mb=$(clamp_value "$xmx_mb" 512 12288)

    xms_mb=$((xmx_mb * 70 / 100))
    xms_mb=$(clamp_value "$xms_mb" 384 "$xmx_mb")

    if [ "$cpu_cores" -le 2 ] && [ "$MC_MAX_PLAYERS" -gt 10 ]; then
        MC_MAX_PLAYERS=10
        MC_VIEW_DISTANCE=6
        MC_SIMULATION_DISTANCE=4
    fi

    if [ "$xmx_mb" -lt 2048 ]; then
        MC_G1_REGION_SIZE="4M"
    elif [ "$xmx_mb" -lt 8192 ]; then
        MC_G1_REGION_SIZE="8M"
    else
        MC_G1_REGION_SIZE="16M"
    fi

    MC_MIN_RAM="${xms_mb}M"
    MC_MAX_RAM="${xmx_mb}M"

    if [ "$disk_type" = "HDD" ]; then
        MC_SYNC_CHUNK_WRITES="true"
        MC_BACKUP_ZSTD_LEVEL="-3"
    else
        MC_SYNC_CHUNK_WRITES="false"
        MC_BACKUP_ZSTD_LEVEL="-1"
    fi

    if [ "$tier" = "LOW" ]; then
        MC_BACKUP_RETENTION_DAYS=5
    elif [ "$tier" = "HIGH" ]; then
        MC_BACKUP_RETENTION_DAYS=10
    else
        MC_BACKUP_RETENTION_DAYS=7
    fi

    service_memory_mb=$((xmx_mb + 512))
    local min_allowed_mb
    local max_allowed_mb
    min_allowed_mb=$((xmx_mb + 128))
    max_allowed_mb=$((total_ram_mb - 256))

    if [ "$max_allowed_mb" -ge "$min_allowed_mb" ]; then
        service_memory_mb=$(clamp_value "$service_memory_mb" "$min_allowed_mb" "$max_allowed_mb")
    else
        service_memory_mb="$xmx_mb"
    fi
    MC_SERVICE_MEMORY_MAX_MB="$service_memory_mb"

    export MC_MIN_RAM
    export MC_MAX_RAM
    export MC_VIEW_DISTANCE
    export MC_SIMULATION_DISTANCE
    export MC_MAX_PLAYERS
    export MC_GC_MAX_PAUSE
    export MC_G1_REGION_SIZE
    export MC_ENTITY_BROADCAST_RANGE
    export MC_SYNC_CHUNK_WRITES
    export MC_BACKUP_ZSTD_LEVEL
    export MC_BACKUP_RETENTION_DAYS
    export MC_SERVICE_MEMORY_MAX_MB
}

write_minecraft_runtime_env() {
    local file_path="$1"

    cat > "$file_path" << EOF
MIN_RAM="$MC_MIN_RAM"
MAX_RAM="$MC_MAX_RAM"
GC_MAX_PAUSE="$MC_GC_MAX_PAUSE"
G1_REGION_SIZE="$MC_G1_REGION_SIZE"
BACKUP_RETENTION_DAYS="$MC_BACKUP_RETENTION_DAYS"
BACKUP_ZSTD_LEVEL="$MC_BACKUP_ZSTD_LEVEL"
EOF
}

write_minecraft_server_properties() {
    local file_path="$1"
    local server_port="$2"
    local online_mode="$3"
    local motd="${4:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"

    cat > "$file_path" << EOF
# Minecraft server properties
server-port=$server_port
server-ip=
online-mode=$online_mode
motd=$motd
max-players=$MC_MAX_PLAYERS
network-compression-threshold=256
prevent-proxy-connections=false

view-distance=$MC_VIEW_DISTANCE
simulation-distance=$MC_SIMULATION_DISTANCE

max-tick-time=60000
max-world-size=29999984
sync-chunk-writes=$MC_SYNC_CHUNK_WRITES
enable-jmx-monitoring=false
enable-status=true

entity-broadcast-range-percentage=$MC_ENTITY_BROADCAST_RANGE
max-build-height=256
spawn-animals=true
spawn-monsters=true
spawn-npcs=true
spawn-protection=0
EOF
}

write_minecraft_tuning_state() {
    local file_path="$1"

    cat > "$file_path" << EOF
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_AVAILABLE_RAM_MB="$HW_AVAILABLE_RAM_MB"
HW_CPU_CORES="$HW_CPU_CORES"
HW_CPU_THREADS="$HW_CPU_THREADS"
HW_DISK_TYPE="$HW_DISK_TYPE"
HW_DETECTED_TIER="$HW_DETECTED_TIER"
HW_TIER="$HW_TIER"
MC_MIN_RAM="$MC_MIN_RAM"
MC_MAX_RAM="$MC_MAX_RAM"
MC_VIEW_DISTANCE="$MC_VIEW_DISTANCE"
MC_SIMULATION_DISTANCE="$MC_SIMULATION_DISTANCE"
MC_MAX_PLAYERS="$MC_MAX_PLAYERS"
MC_GC_MAX_PAUSE="$MC_GC_MAX_PAUSE"
MC_G1_REGION_SIZE="$MC_G1_REGION_SIZE"
MC_SYNC_CHUNK_WRITES="$MC_SYNC_CHUNK_WRITES"
MC_BACKUP_RETENTION_DAYS="$MC_BACKUP_RETENTION_DAYS"
MC_BACKUP_ZSTD_LEVEL="$MC_BACKUP_ZSTD_LEVEL"
MC_SERVICE_MEMORY_MAX_MB="$MC_SERVICE_MEMORY_MAX_MB"
EOF
}
