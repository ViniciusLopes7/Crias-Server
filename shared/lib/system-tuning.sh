#!/bin/bash

# Shared host-level tuning based on detected hardware.

set -u

set_scheduler_if_supported() {
    local device="$1"
    local scheduler="$2"
    local scheduler_file="/sys/block/$device/queue/scheduler"

    if [ ! -w "$scheduler_file" ]; then
        return 0
    fi

    if grep -qw "$scheduler" "$scheduler_file"; then
        echo "$scheduler" > "$scheduler_file" 2>/dev/null || true
    fi
}

set_readahead_kb() {
    local device="$1"
    local value="$2"
    local readahead_file="/sys/block/$device/queue/read_ahead_kb"

    if [ -w "$readahead_file" ]; then
        echo "$value" > "$readahead_file" 2>/dev/null || true
    fi
}

apply_block_device_tuning() {
    local device="${1:-}"
    local rotational

    if [ -z "$device" ]; then
        return 0
    fi

    if [[ "$device" == loop* ]] || [[ "$device" == ram* ]]; then
        return 0
    fi

    if [ ! -r "/sys/block/$device/queue/rotational" ]; then
        return 0
    fi

    rotational=$(cat "/sys/block/$device/queue/rotational" 2>/dev/null)

    if [[ "$device" == nvme* ]]; then
        set_readahead_kb "$device" 1024
        return 0
    fi

    if [ "$rotational" = "1" ]; then
        set_scheduler_if_supported "$device" "bfq"
        set_readahead_kb "$device" 4096
    else
        set_scheduler_if_supported "$device" "mq-deadline"
        set_readahead_kb "$device" 2048
    fi
}

apply_cpupower_tuning() {
    local tier="$1"
    local target_governor="ondemand"

    if [ "$tier" = "MID" ] || [ "$tier" = "HIGH" ]; then
        target_governor="performance"
    fi

    if [ "$target_governor" = "performance" ]; then
        local battery_status_file
        local battery_status

        for battery_status_file in /sys/class/power_supply/BAT*/status; do
            if [ ! -r "$battery_status_file" ]; then
                continue
            fi

            battery_status=$(tr -d '[:space:]' < "$battery_status_file" 2>/dev/null || true)
            if [ "$battery_status" = "Discharging" ]; then
                target_governor="ondemand"
                break
            fi
        done
    fi

    if command -v cpupower >/dev/null 2>&1; then
        local available_list
        available_list=$(cpupower frequency-info -g 2>/dev/null || true)
        if [ -n "$available_list" ] && ! echo "$available_list" | grep -qw "$target_governor"; then
            print_warning "Governor $target_governor nao encontrado; mantendo configuracao padrao do sistema."
            return 0
        fi
        cpupower frequency-set -g "$target_governor" >/dev/null 2>&1 || true
    fi

    local cpupower_conf
    for cpupower_conf in /etc/default/cpupower-service.conf /etc/default/cpupower; do
        if [ -f "$cpupower_conf" ]; then
            if grep -q '^governor=' "$cpupower_conf"; then
                sed -i -E "s|^governor=.*|governor='$target_governor'|" "$cpupower_conf" || true
            else
                printf "governor='%s'\n" "$target_governor" >> "$cpupower_conf"
            fi
        else
            cat > "$cpupower_conf" << EOF
governor='$target_governor'
EOF
        fi
    done

    systemctl enable cpupower >/dev/null 2>&1 || true
}

apply_nofile_limit() {
    local server_user="$1"
    local limits_conf="/etc/security/limits.d/99-crias-gameserver.conf"

    if [ -z "$server_user" ]; then
        return 0
    fi

    cat > "$limits_conf" << EOF
${server_user} soft nofile 65536
${server_user} hard nofile 65536
EOF
}

apply_zram_and_sysctl_tuning() {
    local total_ram_mb="$1"
    local zram_size_mb
    local swappiness
    local zram_conf="/etc/systemd/zram-generator.conf"
    local sysctl_conf="/etc/sysctl.d/99-server-tuning.conf"
    local backup_suffix

    if dry_run_enabled; then
        return 0
    fi

    if [ -z "$total_ram_mb" ] || [ "$total_ram_mb" -le 0 ]; then
        total_ram_mb=4096
    fi

    if [ "$total_ram_mb" -le 4096 ]; then
        zram_size_mb=$((total_ram_mb / 2))
        if [ "$zram_size_mb" -lt 1024 ]; then
            zram_size_mb=1024
        fi
        swappiness=60
    elif [ "$total_ram_mb" -le 8192 ]; then
        zram_size_mb=$((total_ram_mb / 2))
        if [ "$zram_size_mb" -gt 4096 ]; then
            zram_size_mb=4096
        fi
        swappiness=40
    else
        zram_size_mb=2048
        swappiness=20
    fi

    backup_suffix="$(date +%Y%m%d-%H%M%S 2>/dev/null || true)"
    if [ -z "$backup_suffix" ]; then
        backup_suffix="backup"
    fi

    if [ -f "$zram_conf" ]; then
        cp -a "$zram_conf" "${zram_conf}.${backup_suffix}.bak" 2>/dev/null || true
    fi

    cat > "$zram_conf" << EOF
[zram0]
zram-size = ${zram_size_mb}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    if [ -f "$sysctl_conf" ]; then
        cp -a "$sysctl_conf" "${sysctl_conf}.${backup_suffix}.bak" 2>/dev/null || true
    fi

    cat > "$sysctl_conf" << EOF
vm.swappiness=${swappiness}
vm.vfs_cache_pressure=50
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    # Only attempt to load zram module and start the generator service if
    # the host appears to support zram. This avoids noisy failures on systems
    # without the feature.
    if modprobe -n zram >/dev/null 2>&1; then
        modprobe zram >/dev/null 2>&1 || true
        if systemctl list-unit-files | grep -q 'systemd-zram-setup@'; then
            systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
        fi
    fi
    sysctl --system >/dev/null 2>&1 || true
}

apply_common_system_tuning() {
    local server_user="$1"
    local tier="$2"
    local total_ram_mb="$3"

    if dry_run_enabled; then
        return 0
    fi

    # Scope guard: avoid host-wide changes unless explicitly allowed.
    # host = apply sysctl/zram/scheduler/cpupower; anything else skips.
    local scope="${SYSTEM_TUNING_SCOPE:-host}"
    if [ "$scope" != "host" ]; then
        return 0
    fi

    apply_nofile_limit "$server_user"
    apply_zram_and_sysctl_tuning "$total_ram_mb"
    if [ -n "${HW_TARGET_DEVICE:-}" ]; then
        apply_block_device_tuning "$HW_TARGET_DEVICE"
    else
        print_warning "Tuning de I/O pulado: nenhum device de bloco detectado (ZFS/Btrfs/LVM/subvolume)."
        print_warning "Esse comportamento e esperado quando o filesystem gerencia I/O internamente."
    fi
    apply_cpupower_tuning "$tier"
}
