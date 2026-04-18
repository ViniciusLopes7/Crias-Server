#!/bin/bash

# Shared host-level tuning based on detected hardware.

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
    local device
    local rotational

    for device_path in /sys/block/*; do
        device=$(basename "$device_path")

        if [ ! -r "$device_path/queue/rotational" ]; then
            continue
        fi

        rotational=$(cat "$device_path/queue/rotational" 2>/dev/null)

        if [[ "$device" == loop* ]] || [[ "$device" == ram* ]]; then
            continue
        fi

        if [[ "$device" == nvme* ]]; then
            set_readahead_kb "$device" 1024
            continue
        fi

        if [ "$rotational" = "1" ]; then
            set_scheduler_if_supported "$device" "bfq"
            set_readahead_kb "$device" 4096
        else
            set_scheduler_if_supported "$device" "mq-deadline"
            set_readahead_kb "$device" 2048
        fi
    done
}

apply_cpupower_tuning() {
    local tier="$1"
    local target_governor="ondemand"

    if [ "$tier" = "MID" ] || [ "$tier" = "HIGH" ]; then
        target_governor="performance"
    fi

    if command -v cpupower >/dev/null 2>&1; then
        cpupower frequency-set -g "$target_governor" >/dev/null 2>&1 || true
    fi

    if [ -f /etc/default/cpupower ]; then
        sed -i -E "s/^governor=.*/governor='$target_governor'/" /etc/default/cpupower || true
        systemctl enable cpupower >/dev/null 2>&1 || true
    fi
}

apply_nofile_limit() {
    local server_user="$1"

    if [ -z "$server_user" ]; then
        return 0
    fi

    if ! grep -q "^${server_user} soft nofile" /etc/security/limits.conf; then
        echo "${server_user} soft nofile 65536" >> /etc/security/limits.conf
        echo "${server_user} hard nofile 65536" >> /etc/security/limits.conf
    fi
}

apply_zram_and_sysctl_tuning() {
    local total_ram_mb="$1"
    local zram_size_mb
    local swappiness

    if [ -z "$total_ram_mb" ] || [ "$total_ram_mb" -le 0 ]; then
        total_ram_mb=4096
    fi

    if [ "$total_ram_mb" -le 4096 ]; then
        zram_size_mb="$total_ram_mb"
        swappiness=180
    elif [ "$total_ram_mb" -le 8192 ]; then
        zram_size_mb=4096
        swappiness=120
    else
        zram_size_mb=2048
        swappiness=80
    fi

    cat > /etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ${zram_size_mb}M
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

    cat > /etc/sysctl.d/99-server-tuning.conf << EOF
vm.swappiness=${swappiness}
vm.vfs_cache_pressure=50
EOF

    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
    sysctl --system >/dev/null 2>&1 || true
}

apply_common_system_tuning() {
    local server_user="$1"
    local tier="$2"
    local total_ram_mb="$3"

    apply_zram_and_sysctl_tuning "$total_ram_mb"
    apply_block_device_tuning
    apply_cpupower_tuning "$tier"
    apply_nofile_limit "$server_user"
}
