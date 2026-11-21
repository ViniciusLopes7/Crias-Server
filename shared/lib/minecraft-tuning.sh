#!/bin/bash

# Minecraft tuning helpers based on detected hardware profile.

compute_minecraft_tuning() {
    local total_ram_mb="$1"
    local cpu_cores="$2"
    local disk_type="$3"
    local tier="$4"
    # Quinto argumento opcional: disponibilidade instantanea so para diagnostico.
    # Limites herdados de cgroup ja integram o total efetivo do perfil.
    local available_ram_mb="${5:-$total_ram_mb}"
    local pressure_reserve_mb

    local reserve_mb
    local xmx_mb
    local xms_mb
    local service_memory_mb

    # Nao fabrique um heap minimo maior que a memoria disponivel.
    if ! [[ "$total_ram_mb" =~ ^[0-9]+$ ]] || [ "$total_ram_mb" -lt 1024 ]; then
        print_error "Minecraft precisa de pelo menos 1024 MB de RAM efetiva; detectado: ${total_ram_mb:-desconhecido}MB."
        return 1
    fi
    if ! [[ "$available_ram_mb" =~ ^[0-9]{1,7}$ ]] || [ "$available_ram_mb" -gt "$total_ram_mb" ]; then
        print_error "Memoria disponivel inconsistente: ${available_ram_mb:-desconhecida}MB (total ${total_ram_mb}MB)."
        return 1
    fi
    if ! [[ "$cpu_cores" =~ ^[0-9]+$ ]] || [ "$cpu_cores" -le 0 ]; then
        cpu_cores=1
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

    # RAM de instalacao nao deve determinar um limite permanente do jogo.
    # Use somente a RAM fisica/efetiva (ja limitada pelo cgroup ancestral)
    # para o orcamento. MemAvailable e um retrato transitorio: downloads,
    # pacman, page cache e o proprio instalador poderiam reduzir Xmx para
    # toda a vida util do servidor sem nenhuma razao.
    #
    # O servico recebe TODO o orcamento apos a reserva do sistema; seu
    # heap recebe uma parcela, deixando espaco de verdade para stacks de
    # threads, metaspace, NIO/direct buffers, JIT e bibliotecas nativas.
    # MemoryMax nao deve ser Xmx + uma folga arbitraria de 512 MB.
    if [ "$total_ram_mb" -le 1536 ]; then
        reserve_mb=384
    elif [ "$total_ram_mb" -le 2048 ]; then
        reserve_mb=512
    else
        reserve_mb=$(clamp_value "$reserve_mb" 768 8192)
    fi
    local service_budget_mb=$((total_ram_mb - reserve_mb))
    local native_overhead_mb=$((service_budget_mb / 4))
    if [ "$total_ram_mb" -le 1536 ]; then
        native_overhead_mb=$(clamp_value "$native_overhead_mb" 256 512)
    elif [ "$total_ram_mb" -le 2048 ]; then
        native_overhead_mb=$(clamp_value "$native_overhead_mb" 512 768)
    else
        native_overhead_mb=$(clamp_value "$native_overhead_mb" 768 16384)
    fi
    local budget_mb=$((service_budget_mb - native_overhead_mb))
    if [ "$budget_mb" -lt 384 ]; then
        print_error "RAM efetiva insuficiente: total=${total_ram_mb}MB, reserva host=${reserve_mb}MB, folga nativa=${native_overhead_mb}MB."
        return 1
    fi
    xmx_mb="$budget_mb"
    # MemAvailable serve apenas para observar pressao, nunca para limitar
    # permanentemente um host dedicado baseado num instante da instalacao.
    pressure_reserve_mb=0
    MC_EFFECTIVE_AVAILABLE_RAM_MB="$available_ram_mb"
    MC_PRESSURE_RESERVE_MB="$pressure_reserve_mb"
    # Xms conservador e sem AlwaysPreTouch: modpacks pesados nao precisam
    # reservar imediatamente 70% do heap antes de gerar o mundo.
    xms_mb=$((xmx_mb * 30 / 100))
    xms_mb=$(clamp_value "$xms_mb" 256 "$xmx_mb")
    if [ "$xms_mb" -ge "$xmx_mb" ]; then
        xms_mb=$((xmx_mb * 70 / 100))
    fi
    MC_NATIVE_OVERHEAD_MB="$native_overhead_mb"
    MC_HOST_RESERVE_MB="$reserve_mb"

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

    # Integridade primeiro: sync-chunk-writes=true e o padrao do Minecraft
    # para reduzir perdas/corrupcao de chunks apos travamentos ou falta de
    # energia. Detectar SSD/NVMe nao torna essas falhas impossiveis.
    # "false" so com consentimento EXPLICITO do administrador (tradeoff).
    case "${MINECRAFT_SYNC_CHUNK_WRITES:-true}" in
        true|false) MC_SYNC_CHUNK_WRITES="${MINECRAFT_SYNC_CHUNK_WRITES:-true}" ;;
        *)
            print_error "MINECRAFT_SYNC_CHUNK_WRITES invalido (use true ou false)."
            return 1
            ;;
    esac

    case "$disk_type" in
        HDD)      MC_BACKUP_ZSTD_LEVEL="-3" ;;
        SSD|NVME) MC_BACKUP_ZSTD_LEVEL="-1" ;;
        *)        MC_BACKUP_ZSTD_LEVEL="-1" ;;
    esac

    if [ "$tier" = "LOW" ]; then
        MC_BACKUP_RETENTION_DAYS=5
    elif [ "$tier" = "HIGH" ]; then
        MC_BACKUP_RETENTION_DAYS=10
    else
        MC_BACKUP_RETENTION_DAYS=7
    fi

    service_memory_mb="$service_budget_mb"
    # MemoryHigh aplica reclaim gradual perto do teto; MemoryMax e a ultima
    # defesa contra OOM global, preservando SSH e tailscaled fora da unit.
    MC_SERVICE_MEMORY_HIGH_MB=$((service_memory_mb * 95 / 100))
    if [ "$service_memory_mb" -gt "$((total_ram_mb - reserve_mb))" ] \
        || [ "$((xmx_mb + native_overhead_mb))" -ne "$service_memory_mb" ] \
        || [ "$MC_SERVICE_MEMORY_HIGH_MB" -le "$xmx_mb" ]; then
        print_error "Orcamento JVM/systemd inconsistente; recusando configurar."
        return 1
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
    export MC_SERVICE_MEMORY_HIGH_MB
    export MC_NATIVE_OVERHEAD_MB
    export MC_HOST_RESERVE_MB
    export MC_EFFECTIVE_AVAILABLE_RAM_MB
    export MC_PRESSURE_RESERVE_MB
}

# Atualiza somente o limite MemoryMax da unidade Minecraft. Mantem unit
# principal e preferencias administradas pelo operador intactas. Chamado
# SOMENTE com o servico parado pelo manager, para nao reduzir cota em jogo.
write_minecraft_systemd_memory_limit() {
    local max_mb="${1:-}" dir="${2:-/etc/systemd/system/minecraft.service.d}"
    local target="$dir/20-crias-memory.conf" staged="" previous="" verify_out=""
    if ! [[ "$max_mb" =~ ^[0-9]{3,6}$ ]] || [ "$max_mb" -lt 640 ]; then
        print_error "MemoryMax invalido para Minecraft: ${max_mb:-vazio} MB"
        return 1
    fi
    if [ -L "$dir" ] || [ -L "$target" ]; then
        print_error "Recusando drop-in systemd por link simbolico: $target"
        return 1
    fi
    mkdir -p -- "$dir" || return 1
    staged="$(mktemp "$dir/.crias-memory.XXXXXXXX")" || return 1
    if ! printf "[Service]\nMemoryMax=%sM\n" "$max_mb" > "$staged" || ! chmod 0644 "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    if [ -e "$target" ]; then
        if [ ! -f "$target" ]; then rm -f -- "$staged"; return 1; fi
        previous="$(mktemp "$dir/.crias-previous.XXXXXXXX")" || { rm -f -- "$staged"; return 1; }
        if ! cp -a -- "$target" "$previous"; then
            rm -f -- "$staged" "$previous"
            return 1
        fi
    fi
    if ! mv -T -- "$staged" "$target"; then
        rm -f -- "$staged" "$previous"
        return 1
    fi
    # Validacao apos publicar usa o verdadeiro loader de unit + drop-ins.
    local effective_max="" inherited_max=""
    if ! systemctl daemon-reload || ! verify_out="$(systemd-analyze verify minecraft.service 2>&1)" \
        || ! effective_max="$(systemctl show minecraft.service -p MemoryMax --value 2>/dev/null)" \
        || [ "$effective_max" != "$((max_mb * 1048576))" ] \
        || { inherited_max="$(systemctl show minecraft.service -p EffectiveMemoryMax --value 2>/dev/null || true)"; \
             [[ "$inherited_max" =~ ^[0-9]+$ ]] && [ "$inherited_max" -lt "$((max_mb * 1048576))" ]; }; then
        print_error "Validacao do MemoryMax falhou (MemoryMax=${effective_max:-?}; EffectiveMemoryMax=${inherited_max:-?}); restaurando limite anterior."
        [ -z "$verify_out" ] || printf "%s\n" "$verify_out" >&2
        if [ -n "$previous" ]; then
            mv -T -- "$previous" "$target" || return 1
        else
            rm -f -- "$target" || return 1
        fi
        systemctl daemon-reload || true
        return 1
    fi
    [ -z "$previous" ] || rm -f -- "$previous"
    return 0
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

    # (CR-13) Precedencia documentada: override explicito do ambiente
    # (config.env) > valor existente no runtime.env (edicao do operador) >
    # auto-tuning por tier. Config.env agora vaza ("") quando o operador quer
    # o auto-tuning.
    local backup_retention="${BACKUP_RETENTION_DAYS:-$(env_file_read_value "$file_path" BACKUP_RETENTION_DAYS)}"
    if [ -z "$backup_retention" ]; then
        backup_retention="$MC_BACKUP_RETENTION_DAYS"
    fi
    local backup_zstd="${BACKUP_ZSTD_LEVEL:-$(env_file_read_value "$file_path" BACKUP_ZSTD_LEVEL)}"
    if [ -z "$backup_zstd" ]; then
        backup_zstd="$MC_BACKUP_ZSTD_LEVEL"
    fi

    # (CR-06) BACKUP_REQUIRE_CONSISTENT persiste no runtime.env (o
    # backup-cron le de la).
    local backup_require_consistent="${BACKUP_REQUIRE_CONSISTENT:-$(env_file_read_value "$file_path" BACKUP_REQUIRE_CONSISTENT)}"
    backup_require_consistent="${backup_require_consistent:-true}"

    # (EXP-36) MINECRAFT_VERSION para o start-server validar o Java exigido;
    # (EXP-39) SERVER_JAR efetivo (quilt usa mc.jar — o launcher interno do
    # Quilt ocupa server.jar). Preserva valor existente quando o ambiente
    # nao define (reconfigure-hardware roda sem essas variaveis).
    local mc_version="${MINECRAFT_VERSION:-$(env_file_read_value "$file_path" MINECRAFT_VERSION)}"
    local mc_loader="${MINECRAFT_LOADER:-$(env_file_read_value "$file_path" MINECRAFT_LOADER)}"
    mc_loader="${mc_loader:-fabric}"
    case "$mc_loader" in
        vanilla|fabric|quilt|forge|neoforge) ;;
        *)
            print_error "Loader Minecraft invalido no runtime.env: $mc_loader"
            return 1
            ;;
    esac
    local server_jar="${MINECRAFT_SERVER_FILE:-$(env_file_read_value "$file_path" SERVER_JAR)}"
    server_jar="${server_jar:-server.jar}"

    # (CR-08) runtime.env carrega segredos (webhook): modo 0600 — criado com
    # umask 022 virava 0644 legivel por qualquer usuario local.
    write_file_or_dry_run "Gerando runtime.env do Minecraft em $file_path" "$file_path" 0600 << EOF
MIN_RAM="$MC_MIN_RAM"
MAX_RAM="$MC_MAX_RAM"
NATIVE_OVERHEAD_MB="${MC_NATIVE_OVERHEAD_MB:-0}"
GC_MAX_PAUSE="$MC_GC_MAX_PAUSE"
G1_REGION_SIZE="$MC_G1_REGION_SIZE"
BACKUP_RETENTION_DAYS="$backup_retention"
BACKUP_ZSTD_LEVEL="$backup_zstd"
MINECRAFT_LOADER="$mc_loader"
MINECRAFT_VERSION="$mc_version"
SERVER_JAR="$server_jar"
BACKUP_REMOTE_PATH="$backup_remote"
BACKUP_NOTIFY_WEBHOOK="$backup_webhook"
BACKUP_INCLUDE_MODS="$backup_include_mods"
BACKUP_REQUIRE_CONSISTENT="$backup_require_consistent"
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

# (EXP-43) Merge seletivo de chaves em server.properties: remove as chaves
# alvo existentes, preserva TODO o resto (senha, whitelist, comentarios) e
# acrescenta as novas no final. Backup .crias-bak antes de tocar.
# Uso: set_minecraft_properties <arquivo> "key1=val1" ["key2=val2" ...]
set_minecraft_properties() {
    local file_path="$1"
    shift

    if [ ! -f "$file_path" ]; then
        print_warning "set_minecraft_properties: $file_path nao existe."
        return 1
    fi

    cp -a "$file_path" "${file_path}.crias-bak"

    local keys_regex=""
    local kv key
    for kv in "$@"; do
        key="${kv%%=*}"
        keys_regex="${keys_regex:+$keys_regex|}${key}"
    done

    local tmp_file
    tmp_file="$(mktemp_crias_file)"
    awk -v re="^(${keys_regex})=" '$0 !~ re' "$file_path" > "$tmp_file"
    for kv in "$@"; do
        printf '%s\n' "$kv" >> "$tmp_file"
    done
    cat "$tmp_file" > "$file_path"
    rm -f "$tmp_file"
    return 0
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
MC_NATIVE_OVERHEAD_MB="${MC_NATIVE_OVERHEAD_MB:-0}"
MC_HOST_RESERVE_MB="${MC_HOST_RESERVE_MB:-0}"
MC_EFFECTIVE_AVAILABLE_RAM_MB="${MC_EFFECTIVE_AVAILABLE_RAM_MB:-0}"
MC_PRESSURE_RESERVE_MB="${MC_PRESSURE_RESERVE_MB:-0}"
HW_CGROUP_LIMIT_MB="${HW_CGROUP_LIMIT_MB:-0}"
HW_CGROUP_AVAILABLE_MB="${HW_CGROUP_AVAILABLE_MB:-0}"
HW_CPU_QUOTA_CORES="${HW_CPU_QUOTA_CORES:-0}"
EOF
}
