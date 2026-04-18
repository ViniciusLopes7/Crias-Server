#!/bin/bash

# Terraria tuning helpers based on detected hardware profile.

clamp_value() {
    local value="$1"
    local min="$2"
    local max="$3"

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

compute_terraria_tuning() {
    local total_ram_mb="$1"
    local cpu_cores="$2"
    local disk_type="$3"
    local tier="$4"

    local memory_max_mb

    case "$tier" in
        LOW)
            TT_MAX_PLAYERS=8
            TT_WORLD_AUTOCREATE=1
            TT_PRIORITY=1
            TT_NPC_STREAM=30
            TT_BACKUP_RETENTION_DAYS=5
            memory_max_mb=$((total_ram_mb * 35 / 100))
            ;;
        MID)
            TT_MAX_PLAYERS=16
            TT_WORLD_AUTOCREATE=2
            TT_PRIORITY=1
            TT_NPC_STREAM=60
            TT_BACKUP_RETENTION_DAYS=7
            memory_max_mb=$((total_ram_mb * 45 / 100))
            ;;
        HIGH)
            TT_MAX_PLAYERS=64
            TT_WORLD_AUTOCREATE=3
            TT_PRIORITY=1
            TT_NPC_STREAM=90
            TT_BACKUP_RETENTION_DAYS=10
            memory_max_mb=$((total_ram_mb * 55 / 100))
            ;;
        *)
            TT_MAX_PLAYERS=16
            TT_WORLD_AUTOCREATE=2
            TT_PRIORITY=1
            TT_NPC_STREAM=60
            TT_BACKUP_RETENTION_DAYS=7
            memory_max_mb=$((total_ram_mb * 45 / 100))
            ;;
    esac

    if [ "$cpu_cores" -le 2 ] && [ "$TT_MAX_PLAYERS" -gt 12 ]; then
        TT_MAX_PLAYERS=12
    fi

    memory_max_mb=$(clamp_value "$memory_max_mb" 1024 8192)
    TT_SERVICE_MEMORY_MAX_MB="$memory_max_mb"

    if [ "$disk_type" = "HDD" ]; then
        TT_BACKUP_ZSTD_LEVEL="-3"
    else
        TT_BACKUP_ZSTD_LEVEL="-1"
    fi

    export TT_MAX_PLAYERS
    export TT_WORLD_AUTOCREATE
    export TT_PRIORITY
    export TT_NPC_STREAM
    export TT_BACKUP_RETENTION_DAYS
    export TT_BACKUP_ZSTD_LEVEL
    export TT_SERVICE_MEMORY_MAX_MB
}

write_terraria_server_config() {
    local file_path="$1"
    local world_path="$2"
    local server_port="$3"
    local motd="$4"
    local world_name="$5"

    cat > "$file_path" << EOF
worldpath=$world_path
autocreate=$TT_WORLD_AUTOCREATE
worldname=$world_name
maxplayers=$TT_MAX_PLAYERS
port=$server_port
password=
motd=$motd
secure=1
upnp=0
npcstream=$TT_NPC_STREAM
priority=$TT_PRIORITY
language=pt-BR
EOF
}

write_terraria_runtime_env() {
    local file_path="$1"

    cat > "$file_path" << EOF
BACKUP_RETENTION_DAYS="$TT_BACKUP_RETENTION_DAYS"
BACKUP_ZSTD_LEVEL="$TT_BACKUP_ZSTD_LEVEL"
EOF
}

write_terraria_tuning_state() {
    local file_path="$1"

    cat > "$file_path" << EOF
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_AVAILABLE_RAM_MB="$HW_AVAILABLE_RAM_MB"
HW_CPU_CORES="$HW_CPU_CORES"
HW_CPU_THREADS="$HW_CPU_THREADS"
HW_DISK_TYPE="$HW_DISK_TYPE"
HW_DETECTED_TIER="$HW_DETECTED_TIER"
HW_TIER="$HW_TIER"
TT_MAX_PLAYERS="$TT_MAX_PLAYERS"
TT_WORLD_AUTOCREATE="$TT_WORLD_AUTOCREATE"
TT_PRIORITY="$TT_PRIORITY"
TT_NPC_STREAM="$TT_NPC_STREAM"
TT_BACKUP_RETENTION_DAYS="$TT_BACKUP_RETENTION_DAYS"
TT_BACKUP_ZSTD_LEVEL="$TT_BACKUP_ZSTD_LEVEL"
TT_SERVICE_MEMORY_MAX_MB="$TT_SERVICE_MEMORY_MAX_MB"
EOF
}
