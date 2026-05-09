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
    local device
    local pkname
    local base_device

    if [ -z "$probe_path" ]; then
        probe_path="/"
    fi

    if [ ! -e "$probe_path" ]; then
        probe_path="$(dirname "$probe_path")"
    fi

    # Prefer findmnt for robust resolution; fall back to df on older systems.
    if command -v findmnt >/dev/null 2>&1; then
        device=$(findmnt -no SOURCE --target "$probe_path" 2>/dev/null | head -n 1)
    else
        device=$(df -P "$probe_path" 2>/dev/null | awk 'NR==2 {print $1}')
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
    HW_FS_TYPE=$(resolve_mount_fstype_for_path "$target_path")
    HW_TARGET_DEVICE=$(resolve_block_device_for_path "$target_path")
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
    export HW_FS_TYPE
    export HW_TARGET_DEVICE
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
HW_FS_TYPE="$HW_FS_TYPE"
HW_TARGET_DEVICE="$HW_TARGET_DEVICE"
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
