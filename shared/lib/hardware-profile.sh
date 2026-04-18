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

detect_disk_type_for_path() {
    local target_path="$1"
    local probe_path="$target_path"
    local device
    local pkname
    local base_device
    local rotational

    if [ -z "$probe_path" ]; then
        probe_path="/"
    fi

    if [ ! -e "$probe_path" ]; then
        probe_path="$(dirname "$probe_path")"
    fi

    device=$(df -P "$probe_path" 2>/dev/null | awk 'NR==2 {print $1}')
    if [ -z "$device" ]; then
        echo "UNKNOWN"
        return 0
    fi

    pkname=$(lsblk -no PKNAME "$device" 2>/dev/null | head -n 1)
    if [ -n "$pkname" ]; then
        base_device="$pkname"
    else
        base_device=$(basename "$device" | sed -E 's/p?[0-9]+$//')
    fi

    if [[ "$base_device" == nvme* ]]; then
        echo "NVME"
        return 0
    fi

    if [ -r "/sys/block/$base_device/queue/rotational" ]; then
        rotational=$(cat "/sys/block/$base_device/queue/rotational" 2>/dev/null)
        if [ "$rotational" = "1" ]; then
            echo "HDD"
            return 0
        fi
        echo "SSD"
        return 0
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

    if [ "$total_ram_mb" -lt 3072 ] || [ "$cpu_cores" -le 2 ]; then
        echo "LOW"
    elif [ "$total_ram_mb" -lt 12288 ] || [ "$cpu_cores" -le 6 ]; then
        echo "MID"
    else
        echo "HIGH"
    fi
}

detect_hardware_profile() {
    local target_path="$1"
    local forced_tier

    HW_TARGET_PATH="$target_path"
    HW_TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    HW_AVAILABLE_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')
    HW_CPU_CORES=$(nproc 2>/dev/null)
    HW_CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    HW_SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
    HW_DISK_TYPE=$(detect_disk_type_for_path "$target_path")

    if [ -z "$HW_CPU_THREADS" ] || [ "$HW_CPU_THREADS" -le 0 ]; then
        HW_CPU_THREADS="$HW_CPU_CORES"
    fi

    HW_DETECTED_TIER=$(classify_hardware_tier "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES")
    forced_tier=$(normalize_tier "$2")

    if [ -n "$forced_tier" ]; then
        HW_TIER="$forced_tier"
    else
        HW_TIER="$HW_DETECTED_TIER"
    fi

    export HW_TARGET_PATH
    export HW_TOTAL_RAM_MB
    export HW_AVAILABLE_RAM_MB
    export HW_CPU_CORES
    export HW_CPU_THREADS
    export HW_SWAP_MB
    export HW_DISK_TYPE
    export HW_DETECTED_TIER
    export HW_TIER
}

write_hardware_profile_state() {
    local file_path="$1"

    cat > "$file_path" << EOF
HW_TARGET_PATH="$HW_TARGET_PATH"
HW_TOTAL_RAM_MB="$HW_TOTAL_RAM_MB"
HW_AVAILABLE_RAM_MB="$HW_AVAILABLE_RAM_MB"
HW_CPU_CORES="$HW_CPU_CORES"
HW_CPU_THREADS="$HW_CPU_THREADS"
HW_SWAP_MB="$HW_SWAP_MB"
HW_DISK_TYPE="$HW_DISK_TYPE"
HW_DETECTED_TIER="$HW_DETECTED_TIER"
HW_TIER="$HW_TIER"
EOF
}
