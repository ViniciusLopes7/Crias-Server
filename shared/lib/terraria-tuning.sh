#!/bin/bash

# Terraria tuning helpers based on detected hardware profile.

compute_terraria_tuning() {
    local total_ram_mb="$1"
    local cpu_cores="$2"
    local disk_type="$3"
    local tier="$4"

    local memory_max_mb

    # Normalize numeric inputs to avoid "integer expected" errors in comparisons
    total_ram_mb="${total_ram_mb:-0}"
    cpu_cores="${cpu_cores:-0}"
    if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]]; then
        total_ram_mb=0
    fi
    if ! [[ "$cpu_cores" =~ ^[0-9]+$ ]]; then
        cpu_cores=0
    fi

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

    # (CR-03) Merge seletivo: so as chaves de tuning sao gerenciadas. A senha
    # (password=) e qualquer chave personalizada do operador sao
    # PRESERVADAS — antes o arquivo era recriado inteiro com password= vazio,
    # e um reconfigure-hardware apagava a senha do servidor. NUNCA geramos
    # password= (nem vazio): quem nao tem senha mantem o que tinha.
    local managed_keys='^(worldpath|autocreate|worldname|maxplayers|port|motd|secure|upnp|npcstream|priority|language)='

    if dry_run_enabled; then
        print_step "[DRY_RUN] Gerando serverconfig.txt do Terraria em $file_path"
        return 0
    fi

    local tmp_new
    tmp_new="$(mktemp_crias_file)"
    {
        printf 'worldpath=%s\n' "$world_path"
        printf 'autocreate=%s\n' "$TT_WORLD_AUTOCREATE"
        printf 'worldname=%s\n' "$world_name"
        printf 'maxplayers=%s\n' "$TT_MAX_PLAYERS"
        printf 'port=%s\n' "$server_port"
        printf 'motd=%s\n' "$motd"
        printf 'secure=1\n'
        printf 'upnp=0\n'
        printf 'npcstream=%s\n' "$TT_NPC_STREAM"
        printf 'priority=%s\n' "$TT_PRIORITY"
        printf 'language=pt-BR\n'
    } > "$tmp_new"

    if [ -f "$file_path" ]; then
        cp -a "$file_path" "${file_path}.crias-bak"
        local tmp_merged
        tmp_merged="$(mktemp_crias_file)"
        {
            cat "$tmp_new"
            awk -v re="$managed_keys" '$0 !~ re' "$file_path"
        } > "$tmp_merged"
        cat "$tmp_merged" > "$file_path"
        rm -f "$tmp_merged"
    else
        cat "$tmp_new" > "$file_path"
    fi

    rm -f "$tmp_new"
}

write_terraria_runtime_env() {
    local file_path="$1"

    # Modo explicito (CR-12): o launcher le esta chave para decidir tML vs
    # vanilla com prioridade sobre a deteccao por artefato (o marcador
    # ScriptCaller.sh fica para tras numa migracao tML -> vanilla).
    # Backup (CR-15): idem write_minecraft_runtime_env.
    local backup_remote="${BACKUP_REMOTE_PATH:-$(env_file_read_value "$file_path" BACKUP_REMOTE_PATH)}"
    local backup_webhook="${BACKUP_NOTIFY_WEBHOOK:-$(env_file_read_value "$file_path" BACKUP_NOTIFY_WEBHOOK)}"
    local backup_include_mods="${BACKUP_INCLUDE_MODS:-$(env_file_read_value "$file_path" BACKUP_INCLUDE_MODS)}"

    case "$backup_remote$backup_webhook" in
        *'"'*|*'$'*|*'`'*|*$'\n'*)
            print_warning "BACKUP_REMOTE_PATH/BACKUP_NOTIFY_WEBHOOK contem caracteres nao suportados (\$ \" \`) — chaves nao serao persistidas no runtime.env."
            backup_remote=""
            backup_webhook=""
            ;;
    esac

    # (CR-13) Precedencia: ambiente (config.env) > runtime.env existente >
    # auto-tuning por tier (config.env vazio = automatico).
    local backup_retention="${BACKUP_RETENTION_DAYS:-$(env_file_read_value "$file_path" BACKUP_RETENTION_DAYS)}"
    if [ -z "$backup_retention" ]; then
        backup_retention="$TT_BACKUP_RETENTION_DAYS"
    fi
    local backup_zstd="${BACKUP_ZSTD_LEVEL:-$(env_file_read_value "$file_path" BACKUP_ZSTD_LEVEL)}"
    if [ -z "$backup_zstd" ]; then
        backup_zstd="$TT_BACKUP_ZSTD_LEVEL"
    fi

    # (CR-08) runtime.env com segredos (webhook): 0600.
    write_file_or_dry_run "Gerando runtime.env do Terraria em $file_path" "$file_path" 0600 << EOF
BACKUP_RETENTION_DAYS="$backup_retention"
BACKUP_ZSTD_LEVEL="$backup_zstd"
TERRARIA_USE_TMODLOADER="${TERRARIA_USE_TMODLOADER:-false}"
BACKUP_REMOTE_PATH="$backup_remote"
BACKUP_NOTIFY_WEBHOOK="$backup_webhook"
BACKUP_INCLUDE_MODS="$backup_include_mods"
EOF
}

write_terraria_tuning_state() {
    local file_path="$1"

    write_file_or_dry_run "Gerando hardware-profile.env do Terraria em $file_path" "$file_path" << EOF
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_FS_TYPE="$HW_FS_TYPE"
HW_TARGET_DEVICE="$HW_TARGET_DEVICE"
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
