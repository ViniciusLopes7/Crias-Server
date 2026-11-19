#!/bin/bash

# Minecraft tuning helpers based on detected hardware profile.

compute_minecraft_tuning() {
    local total_ram_mb="$1"
    local cpu_cores="$2"
    local disk_type="$3"
    local tier="$4"

    local reserve_mb
    local xmx_mb
    local xms_mb
    local service_memory_mb

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
            reserve_mb=$((total_ram_mb * 25 / 100))
            MC_VIEW_DISTANCE=4
            MC_SIMULATION_DISTANCE=3
            MC_MAX_PLAYERS=6
            MC_GC_MAX_PAUSE=250
            MC_ENTITY_BROADCAST_RANGE=60
            ;;
        MID)
            reserve_mb=$((total_ram_mb * 20 / 100))
            MC_VIEW_DISTANCE=8
            MC_SIMULATION_DISTANCE=5
            MC_MAX_PLAYERS=16
            MC_GC_MAX_PAUSE=200
            MC_ENTITY_BROADCAST_RANGE=80
            ;;
        HIGH)
            reserve_mb=$((total_ram_mb * 15 / 100))
            MC_VIEW_DISTANCE=12
            MC_SIMULATION_DISTANCE=8
            MC_MAX_PLAYERS=40
            MC_GC_MAX_PAUSE=150
            MC_ENTITY_BROADCAST_RANGE=100
            ;;
        *)
            reserve_mb=$((total_ram_mb * 20 / 100))
            MC_VIEW_DISTANCE=8
            MC_SIMULATION_DISTANCE=5
            MC_MAX_PLAYERS=16
            MC_GC_MAX_PAUSE=200
            MC_ENTITY_BROADCAST_RANGE=80
            ;;
    esac

    reserve_mb=$(clamp_value "$reserve_mb" 1000 8192)

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

    service_memory_mb=$((xmx_mb + 1792))
    local min_allowed_mb
    local max_allowed_mb
    min_allowed_mb=$((xmx_mb + 1024))
    max_allowed_mb=$((total_ram_mb - 256))

    if [ "$max_allowed_mb" -ge "$min_allowed_mb" ]; then
        service_memory_mb=$(clamp_value "$service_memory_mb" "$min_allowed_mb" "$max_allowed_mb")
    else
        # If computed min exceeds max, use max as long as it stays above Xmx.
        # Ensures systemd memory cap stays above JVM Xmx where possible.
        if [ "$max_allowed_mb" -gt "$xmx_mb" ]; then
            service_memory_mb="$max_allowed_mb"
        else
            service_memory_mb="$xmx_mb"
        fi
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

    # Configuracao de backup (CR-15): BACKUP_REMOTE_PATH/BACKUP_NOTIFY_WEBHOOK
    # vindas do config.env sao propagadas ao runtime.env (o backup-cron le o
    # runtime.env via backup_init). Valores ja existentes no arquivo sao
    # preservados quando o ambiente nao os define (reconfigure-hardware roda
    # sem elas e nao pode apaga-las).
    local backup_remote="${BACKUP_REMOTE_PATH:-$(env_file_read_value "$file_path" BACKUP_REMOTE_PATH)}"
    local backup_webhook="${BACKUP_NOTIFY_WEBHOOK:-$(env_file_read_value "$file_path" BACKUP_NOTIFY_WEBHOOK)}"
    local backup_include_mods="${BACKUP_INCLUDE_MODS:-$(env_file_read_value "$file_path" BACKUP_INCLUDE_MODS)}"

    # runtime.env e carregado com `source` pelo backup-cron: valores com ",
    # $, ` ou newline entre aspas duplas quebrariam/expandiriam no parse.
    # Chaves com esses caracteres nao sao persistidas (admin pode editar o
    # runtime.env manualmente).
    case "$backup_remote$backup_webhook" in
        *'"'*|*'$'*|*'`'*|*$'\n'*)
            print_warning "BACKUP_REMOTE_PATH/BACKUP_NOTIFY_WEBHOOK contem caracteres nao suportados (\$ \" \`) — chaves nao serao persistidas no runtime.env."
            backup_remote=""
            backup_webhook=""
            ;;
    esac

    write_file_or_dry_run "Gerando runtime.env do Minecraft em $file_path" "$file_path" << EOF
MIN_RAM="$MC_MIN_RAM"
MAX_RAM="$MC_MAX_RAM"
GC_MAX_PAUSE="$MC_GC_MAX_PAUSE"
G1_REGION_SIZE="$MC_G1_REGION_SIZE"
BACKUP_RETENTION_DAYS="$MC_BACKUP_RETENTION_DAYS"
BACKUP_ZSTD_LEVEL="$MC_BACKUP_ZSTD_LEVEL"
MINECRAFT_LOADER="${MINECRAFT_LOADER:-fabric}"
BACKUP_REMOTE_PATH="$backup_remote"
BACKUP_NOTIFY_WEBHOOK="$backup_webhook"
BACKUP_INCLUDE_MODS="$backup_include_mods"
EOF
}

write_minecraft_server_properties() {
    local file_path="$1"
    local server_port="$2"
    local online_mode="$3"
    local motd="${4:-§6§l🏰 REINO DOS CRIAS 🏰\\n§eAdrenaline + QoL §7| §aA resenha nunca morre...§r}"

    # Chaves gerenciadas pelo Crias (CR-09): qualquer outra chave existente
    # (enable-rcon, rcon.password, whitelist, level-name, op-levels,
    # comentarios...) e PRESERVADA por merge — reconfigure-hardware nao pode
    # apagar a configuracao do administrador (antes: truncava o arquivo).
    local managed_keys='^(server-port|server-ip|online-mode|motd|max-players|network-compression-threshold|prevent-proxy-connections|view-distance|simulation-distance|max-tick-time|max-world-size|sync-chunk-writes|enable-jmx-monitoring|enable-status|entity-broadcast-range-percentage|spawn-animals|spawn-monsters|spawn-npcs|spawn-protection)='

    if dry_run_enabled; then
        print_step "[DRY_RUN] Gerando server.properties do Minecraft em $file_path"
        return 0
    fi

    local tmp_new
    tmp_new="$(mktemp_crias_file)"

    {
        printf '%s\n' '# Minecraft server properties'
        printf 'server-port=%s\n' "$server_port"
        printf '%s\n' 'server-ip='
        printf 'online-mode=%s\n' "$online_mode"
        printf 'motd=%s\n' "$motd"
        printf 'max-players=%s\n' "$MC_MAX_PLAYERS"
        printf '%s\n' 'network-compression-threshold=256'
        printf '%s\n' 'prevent-proxy-connections=false'
        printf '\n'
        printf 'view-distance=%s\n' "$MC_VIEW_DISTANCE"
        printf 'simulation-distance=%s\n' "$MC_SIMULATION_DISTANCE"
        printf '\n'
        printf '%s\n' 'max-tick-time=60000'
        printf '%s\n' 'max-world-size=29999984'
        printf 'sync-chunk-writes=%s\n' "$MC_SYNC_CHUNK_WRITES"
        printf '%s\n' 'enable-jmx-monitoring=false'
        printf '%s\n' 'enable-status=true'
        printf '\n'
        printf 'entity-broadcast-range-percentage=%s\n' "$MC_ENTITY_BROADCAST_RANGE"
        printf '%s\n' 'spawn-animals=true'
        printf '%s\n' 'spawn-monsters=true'
        printf '%s\n' 'spawn-npcs=true'
        printf '%s\n' 'spawn-protection=0'
    } > "$tmp_new"

    if [ -f "$file_path" ]; then
        # Backup do estado pre-merge (ultima versao pre-instalacao).
        cp -a "$file_path" "${file_path}.crias-bak"

        # Merge: bloco gerenciado novo + tudo que NAO e chave gerenciada do
        # arquivo atual (comentarios, chaves do admin). O jogo le a ULTIMA
        # ocorrencia de cada chave — as gerenciadas antigas sao descartadas
        # e as novas (no topo) prevalecem. ATENCAO: escrever em tmp e copiar
        # por cima — redirecionar `> file` direto truncaria o arquivo ANTES
        # do awk te-lo lido.
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
    chmod 0640 "$file_path"
}

write_minecraft_tuning_state() {
    local file_path="$1"

    write_file_or_dry_run "Gerando hardware-profile.env do Minecraft em $file_path" "$file_path" << EOF
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_FS_TYPE="$HW_FS_TYPE"
HW_TARGET_DEVICE="$HW_TARGET_DEVICE"
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
