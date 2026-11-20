#!/bin/bash

# Hardware profiling helpers for dynamic tuning.

normalize_tier() {
    local value="${1^^}"
    case "$value" in
        LOW|MID|HIGH)
            echo "$value"
            ;;
        *)
            echo ""
            ;;
    esac
}

resolve_mount_fstype_for_path() {
    local target_path="$1"
    local probe_path="$target_path"
    local fstype

    if [ -z "$probe_path" ]; then
        probe_path="/"
    fi

    if [ ! -e "$probe_path" ]; then
        probe_path="$(dirname "$probe_path")"
    fi

    if command -v findmnt >/dev/null 2>&1; then
        fstype=$(findmnt -no FSTYPE --target "$probe_path" 2>/dev/null | head -n 1)
        if [ -n "$fstype" ]; then
            echo "$fstype"
            return 0
        fi
    fi

    fstype=$(stat -f -c '%T' "$probe_path" 2>/dev/null || true)
    case "$fstype" in
        zfs|btrfs)
            echo "$fstype"
            return 0
            ;;
    esac

    echo ""
}

resolve_mount_source_for_path() {
    local target_path="$1"
    local probe_path="$target_path"
    local source

    if [ -z "$probe_path" ]; then
        probe_path="/"
    fi

    if [ ! -e "$probe_path" ]; then
        probe_path="$(dirname "$probe_path")"
    fi

    if command -v findmnt >/dev/null 2>&1; then
        source=$(findmnt -no SOURCE --target "$probe_path" 2>/dev/null | head -n 1)
        if [ -n "$source" ]; then
            echo "$source"
            return 0
        fi
    fi

    echo ""
}

resolve_block_device_for_path() {
    local target_path="$1"
    local probe_path="$target_path"
    local device=""
    local pkname
    local base_device

    if [ -z "$probe_path" ]; then
        probe_path="/"
    fi

    if [ ! -e "$probe_path" ]; then
        probe_path="$(dirname "$probe_path")"
    fi

    # Prefer findmnt for robust resolution.
    if command -v findmnt >/dev/null 2>&1; then
        device=$(findmnt -no SOURCE --target "$probe_path" 2>/dev/null | head -n 1)
    fi

    if [ -z "$device" ] || [ "${device#/dev/}" = "$device" ]; then
        echo ""
        return 0
    fi

    pkname=$(lsblk -no PKNAME "$device" 2>/dev/null | head -n 1)
    if [ -n "$pkname" ]; then
        echo "$pkname"
        return 0
    fi

    base_device=$(basename "$device" | sed -E 's/p?[0-9]+$//')
    echo "$base_device"
}

detect_disk_type_for_path() {
    local target_path="$1"
    local fs_type
    local mount_source
    local base_device
    local rotational
    local source_type

    fs_type=$(resolve_mount_fstype_for_path "$target_path")
    mount_source=$(resolve_mount_source_for_path "$target_path")

    case "$fs_type" in
        zfs)
            echo "ZFS"
            return 0
            ;;
    esac

    base_device=$(resolve_block_device_for_path "$target_path")
    if [ -z "$base_device" ]; then
        case "$fs_type" in
            btrfs)
                echo "BTRFS"
                return 0
                ;;
        esac
        if command -v print_warning >/dev/null 2>&1; then
            print_warning "Nao foi possivel inferir o tipo de disco para $target_path; usando UNKNOWN." >&2
        fi
        echo "UNKNOWN"
        return 0
    fi

    if [ "$fs_type" = "btrfs" ]; then
        echo "BTRFS"
        return 0
    fi

    if [ -n "$mount_source" ] && [ "${mount_source#/dev/}" != "$mount_source" ]; then
        source_type=$(lsblk -no TYPE "$mount_source" 2>/dev/null | head -n 1)
        if [ "$source_type" = "lvm" ]; then
            echo "LVM"
            return 0
        fi
    fi

    if [[ "$base_device" == nvme* ]]; then
        echo "NVME"
        return 0
    fi

    if [ -r "/sys/block/$base_device/queue/rotational" ]; then
        # read -r avoids fork/exec of cat for small /sys files.
        read -r rotational < "/sys/block/$base_device/queue/rotational" 2>/dev/null || rotational=""
        if [ "$rotational" = "1" ]; then
            echo "HDD"
            return 0
        fi
        echo "SSD"
        return 0
    fi

    if command -v print_warning >/dev/null 2>&1; then
        print_warning "Nao foi possivel inferir o tipo de disco para $target_path; usando UNKNOWN." >&2
    fi
    echo "UNKNOWN"
}

classify_hardware_tier() {
    local total_ram_mb="$1"
    local cpu_cores="$2"

    if [ -z "$total_ram_mb" ] || [ -z "$cpu_cores" ]; then
        echo "MID"
        return 0
    fi

    # Hardware tier thresholds (with sane defaults).
    local low_ram="${HW_LOW_TIER_MAX_RAM_MB:-3072}"
    local low_cpu="${HW_LOW_TIER_MAX_CPU_CORES:-2}"
    local mid_ram="${HW_MID_TIER_MAX_RAM_MB:-12288}"
    local mid_cpu="${HW_MID_TIER_MAX_CPU_CORES:-6}"

    if [ "$total_ram_mb" -lt "$low_ram" ] || [ "$cpu_cores" -le "$low_cpu" ]; then
        echo "LOW"
    elif [ "$total_ram_mb" -lt "$mid_ram" ] || [ "$cpu_cores" -le "$mid_cpu" ]; then
        echo "MID"
    else
        echo "HIGH"
    fi
}

# Le o menor limite memory.max da hierarquia cgroup v2 (incluindo os pais).
# Opcionalmente recebe raiz e caminho relativo para testes sem root.
cgroup_v2_effective_memory_mb() {
    local root="${1:-/sys/fs/cgroup}" rel="${2:-}" cur bytes limit_mb min_mb=""
    if [ "$#" -lt 2 ]; then
        rel="$(awk -F: '$1=="0" && $2=="" {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
    fi
    # Nao aceite traversal, barras duplas ou caracteres inesperados em path.
    if [ "$rel" != "/" ] && ! [[ "$rel" =~ ^(/[-A-Za-z0-9_.:@]+)+$ ]]; then
        return 1
    fi
    # O regex de caracteres sozinho nao impede componentes /../ ou /./.
    if [[ "$rel" =~ (^|/)\.\.(/|$) || "$rel" =~ (^|/)\.(/|$) ]]; then
        return 1
    fi
    if [ "$rel" = "/" ]; then rel=""; fi
    cur="${root%/}${rel}"
    while :; do
        if [ -f "$cur/memory.max" ]; then
            bytes="$(cat "$cur/memory.max" 2>/dev/null || true)"
            if [[ "$bytes" =~ ^[0-9]{1,18}$ ]] && [ "$bytes" -gt 0 ]; then
                limit_mb=$((bytes / 1048576))
                [ "$limit_mb" -gt 0 ] || limit_mb=1
                if [ -z "$min_mb" ] || [ "$limit_mb" -lt "$min_mb" ]; then
                    min_mb="$limit_mb"
                fi
            fi
        fi
        [ "$cur" = "${root%/}" ] && break
        cur="${cur%/*}"
        # A raiz e fixa; nao percorra caminhos fora dela.
        case "$cur" in "${root%/}"|"${root%/}/"*) ;; *) break ;; esac
    done
    [ -n "$min_mb" ] || return 1
    printf "%s\n" "$min_mb"
}
# Cotas efetivas de CPU podem estar em qualquer ancestral da slice systemd.
# Arredondamento para baixo evita superdimensionar um host com 1,5 vCPU.
cgroup_v2_effective_cpu_cores() {
    local root="${1:-/sys/fs/cgroup}" rel="${2:-}" cur quota period cores min_cores=""
    if [ "$#" -lt 2 ]; then
        rel="$(awk -F: '$1=="0" && $2=="" {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
    fi
    if [ "$rel" != "/" ] && ! [[ "$rel" =~ ^(/[-A-Za-z0-9_.:@]+)+$ ]]; then return 1; fi
    if [[ "$rel" =~ (^|/)\.\.(/|$) || "$rel" =~ (^|/)\.(/|$) ]]; then return 1; fi
    [ "$rel" = "/" ] && rel=""
    cur="${root%/}${rel}"
    while :; do
        if [ -r "$cur/cpu.max" ]; then
            read -r quota period < "$cur/cpu.max" || true
            if [[ "$quota" =~ ^[0-9]{1,15}$ ]] && [[ "$period" =~ ^[0-9]{1,12}$ ]] && [ "$period" -gt 0 ]; then
                cores=$((quota / period))
                [ "$cores" -ge 1 ] || cores=1
                if [ -z "$min_cores" ] || [ "$cores" -lt "$min_cores" ]; then min_cores="$cores"; fi
            fi
        fi
        [ "$cur" = "${root%/}" ] && break
        cur="${cur%/*}"
        case "$cur" in "${root%/}"|"${root%/}/"*) ;; *) break ;; esac
    done
    [ -n "$min_cores" ] || return 1
    printf '%s\n' "$min_cores"
}

# Folga do cgroup, nao apenas seu teto. memory.current e conservador
# (inclui cache reclamavel); reduz risco de alocar em slice ja pressionada.
cgroup_v2_available_memory_mb() {
    local root="${1:-/sys/fs/cgroup}" rel="${2:-}" cur max_bytes current_bytes available_mb min_available=""
    if [ "$#" -lt 2 ]; then
        rel="$(awk -F: '$1=="0" && $2=="" {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
    fi
    if [ "$rel" != "/" ] && ! [[ "$rel" =~ ^(/[-A-Za-z0-9_.:@]+)+$ ]]; then return 1; fi
    if [[ "$rel" =~ (^|/)\.\.(/|$) || "$rel" =~ (^|/)\.(/|$) ]]; then return 1; fi
    [ "$rel" = "/" ] && rel=""
    cur="${root%/}${rel}"
    while :; do
        if [ -r "$cur/memory.max" ] && [ -r "$cur/memory.current" ]; then
            read -r max_bytes < "$cur/memory.max" || max_bytes=""
            read -r current_bytes < "$cur/memory.current" || current_bytes=""
            if [[ "$max_bytes" =~ ^[0-9]{1,18}$ ]] && [[ "$current_bytes" =~ ^[0-9]{1,18}$ ]] && [ "$max_bytes" -gt 0 ]; then
                if [ "$current_bytes" -ge "$max_bytes" ]; then
                    available_mb=0
                else
                    available_mb=$(((max_bytes - current_bytes) / 1048576))
                fi
                if [ -z "$min_available" ] || [ "$available_mb" -lt "$min_available" ]; then min_available="$available_mb"; fi
            fi
        fi
        [ "$cur" = "${root%/}" ] && break
        cur="${cur%/*}"
        case "$cur" in "${root%/}"|"${root%/}/"*) ;; *) break ;; esac
    done
    [ -n "$min_available" ] || return 1
    printf '%s\n' "$min_available"
}
detect_hardware_profile() {
    local target_path="${1:-/}" forced_tier
    local meminfo_file="${3:-/proc/meminfo}"
    local cg_limit_mb="" cg_available_mb="" cg_bytes="" cg_cpu_cores=""
    local free_output=""

    HW_TARGET_PATH="$target_path"
    HW_FS_TYPE=$(resolve_mount_fstype_for_path "$target_path")
    HW_TARGET_DEVICE=$(resolve_block_device_for_path "$target_path")

    # Um snapshot /proc/meminfo evita que tres chamadas a free produzam
    # valores de instantes diferentes. Caminho alternativo serve aos testes.
    if [ -r "$meminfo_file" ]; then
        read -r HW_TOTAL_RAM_MB HW_AVAILABLE_RAM_MB HW_SWAP_MB < <(
            awk '/^MemTotal:/ {t=int($2/1024)}
                 /^MemAvailable:/ {a=int($2/1024)}
                 /^SwapTotal:/ {s=int($2/1024)}
                 END {printf "%d %d %d\n", t, a, s}' "$meminfo_file"
        )
    elif command -v free >/dev/null 2>&1; then
        free_output="$(free -m 2>/dev/null || true)"
        HW_TOTAL_RAM_MB="$(awk '/^Mem:/{print $2; exit}' <<< "$free_output")"
        HW_AVAILABLE_RAM_MB="$(awk '/^Mem:/{print $7; exit}' <<< "$free_output")"
        HW_SWAP_MB="$(awk '/^Swap:/{print $2; exit}' <<< "$free_output")"
    fi
    for field in HW_TOTAL_RAM_MB HW_AVAILABLE_RAM_MB HW_SWAP_MB; do
        if ! [[ "${!field:-}" =~ ^[0-9]{1,9}$ ]]; then printf -v "$field" '%s' 0; fi
    done
    [ "$HW_AVAILABLE_RAM_MB" -le "$HW_TOTAL_RAM_MB" ] || HW_AVAILABLE_RAM_MB="$HW_TOTAL_RAM_MB"

    # A slice que executa o instalador pode ser menor que a RAM da maquina.
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        cg_limit_mb="$(cgroup_v2_effective_memory_mb || true)"
        cg_available_mb="$(cgroup_v2_available_memory_mb || true)"
        cg_cpu_cores="$(cgroup_v2_effective_cpu_cores || true)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        cg_bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
        if [[ "$cg_bytes" =~ ^[0-9]{1,18}$ ]] && [ "$cg_bytes" -gt 0 ] \
            && [ "$cg_bytes" -lt 4611686018427387904 ]; then
            cg_limit_mb=$((cg_bytes / 1048576))
        fi
    fi

    HW_CGROUP_LIMIT_MB="${cg_limit_mb:-0}"
    HW_CGROUP_AVAILABLE_MB="${cg_available_mb:-0}"
    HW_CPU_QUOTA_CORES="${cg_cpu_cores:-0}"
    if [[ "$cg_limit_mb" =~ ^[0-9]+$ ]] && [ "$cg_limit_mb" -gt 0 ] \
        && [ "$HW_TOTAL_RAM_MB" -gt 0 ] && [ "$cg_limit_mb" -lt "$HW_TOTAL_RAM_MB" ]; then
        if command -v print_warning >/dev/null 2>&1; then
            print_warning "Cgroup limita RAM a ${cg_limit_mb}MB (host ${HW_TOTAL_RAM_MB}MB): orcamento ajustado." >&2
        fi
        HW_TOTAL_RAM_MB="$cg_limit_mb"
        [ "$HW_AVAILABLE_RAM_MB" -le "$HW_TOTAL_RAM_MB" ] || HW_AVAILABLE_RAM_MB="$HW_TOTAL_RAM_MB"
    fi
    if [[ "$cg_available_mb" =~ ^[0-9]+$ ]] && [ "$cg_available_mb" -lt "$HW_AVAILABLE_RAM_MB" ]; then
        HW_AVAILABLE_RAM_MB="$cg_available_mb"
    fi

    HW_CPU_CORES="$(nproc 2>/dev/null || true)"
    HW_CPU_THREADS="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)"
    if ! [[ "$HW_CPU_CORES" =~ ^[0-9]+$ ]] || [ "$HW_CPU_CORES" -le 0 ]; then HW_CPU_CORES=1; fi
    if [[ "$cg_cpu_cores" =~ ^[0-9]+$ ]] && [ "$cg_cpu_cores" -gt 0 ] && [ "$cg_cpu_cores" -lt "$HW_CPU_CORES" ]; then
        HW_CPU_CORES="$cg_cpu_cores"
    fi
    if ! [[ "$HW_CPU_THREADS" =~ ^[0-9]+$ ]] || [ "$HW_CPU_THREADS" -le 0 ]; then HW_CPU_THREADS="$HW_CPU_CORES"; fi
    HW_DISK_TYPE=$(detect_disk_type_for_path "$target_path")

    HW_DETECTED_TIER=$(classify_hardware_tier "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES")
    forced_tier=$(normalize_tier "${2:-}")
    if [ -n "$forced_tier" ]; then HW_TIER="$forced_tier"; else HW_TIER="$HW_DETECTED_TIER"; fi

    export HW_TARGET_PATH HW_FS_TYPE HW_TARGET_DEVICE HW_TOTAL_RAM_MB HW_AVAILABLE_RAM_MB
    export HW_CGROUP_LIMIT_MB HW_CGROUP_AVAILABLE_MB HW_CPU_QUOTA_CORES
    export HW_CPU_CORES HW_CPU_THREADS HW_SWAP_MB HW_DISK_TYPE HW_DETECTED_TIER HW_TIER
}

write_hardware_profile_state() {
    local file_path="$1"

    cat > "$file_path" << EOF
HW_TARGET_PATH="$HW_TARGET_PATH"
HW_FS_TYPE="$HW_FS_TYPE"
HW_TARGET_DEVICE="$HW_TARGET_DEVICE"
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_AVAILABLE_RAM_MB="$HW_AVAILABLE_RAM_MB"
HW_CGROUP_LIMIT_MB="${HW_CGROUP_LIMIT_MB:-0}"
HW_CGROUP_AVAILABLE_MB="${HW_CGROUP_AVAILABLE_MB:-0}"
HW_CPU_QUOTA_CORES="${HW_CPU_QUOTA_CORES:-0}"
HW_CPU_CORES="$HW_CPU_CORES"
HW_CPU_THREADS="$HW_CPU_THREADS"
HW_SWAP_MB="$HW_SWAP_MB"
HW_DISK_TYPE="$HW_DISK_TYPE"
HW_DETECTED_TIER="$HW_DETECTED_TIER"
HW_TIER="$HW_TIER"
EOF
}
