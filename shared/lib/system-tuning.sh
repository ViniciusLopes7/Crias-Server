#!/bin/bash

# Shared host-level tuning based on detected hardware.
# NOTE: do not use `set -u` in sourced libs; caller decides error policy.

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

    # read -r is more efficient than cat (no fork/exec) for small /sys files.
    read -r rotational < "/sys/block/$device/queue/rotational" 2>/dev/null || rotational=""

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
            break
        else
            cat > "$cpupower_conf" << EOF
governor='$target_governor'
EOF
            break
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

    # Ensure /etc/security/limits.d/ exists.
    # May be missing on some systems (containers, minimal installs).
    if [ ! -d "/etc/security/limits.d" ]; then
        mkdir -p "/etc/security/limits.d" 2>/dev/null || {
            warn "Não foi possível criar /etc/security/limits.d/ — pulando nofile limit."
            return 0
        }
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

    # Nao sobrescreva zram/sysctl ja administrados pelo usuario, distro ou
    # outra ferramenta. Uma nova instalacao so cria arquivos ausentes; Crias
    # so altera arquivos que ele mesmo marcou como gerenciados.
    local marker="# Managed by Crias-Server (automatic host tuning)"
    local zram_managed=true sysctl_managed=true
    if [ -e "$zram_conf" ] && ! grep -Fqx "$marker" "$zram_conf" 2>/dev/null; then
        print_warning "ZRAM existente nao gerenciada pelo Crias; arquivo preservado: $zram_conf" >&2
        zram_managed=false
    fi
    if [ -e "$sysctl_conf" ] && ! grep -Fqx "$marker" "$sysctl_conf" 2>/dev/null; then
        print_warning "sysctl existente nao gerenciado pelo Crias; arquivo preservado: $sysctl_conf" >&2
        sysctl_managed=false
    fi

    local staged=""
    if [ "$zram_managed" = true ]; then
        mkdir -p -- "$(dirname "$zram_conf")" || return 1
        staged="$(mktemp "${zram_conf}.XXXXXX")" || return 1
        if ! printf '%s\n[zram0]\nzram-size = %sM\ncompression-algorithm = zstd\nswap-priority = 100\nfs-type = swap\n' "$marker" "$zram_size_mb" > "$staged" \
            || ! chmod 0644 "$staged" || ! mv -T -- "$staged" "$zram_conf"; then
            rm -f -- "$staged"
            print_warning "Falha ao escrever ZRAM; configuracao anterior preservada quando possivel." >&2
            return 1
        fi
    fi
    if [ "$sysctl_managed" = true ]; then
        mkdir -p -- "$(dirname "$sysctl_conf")" || return 1
        staged="$(mktemp "${sysctl_conf}.XXXXXX")" || return 1
        if ! printf '%s\nvm.swappiness=%s\nvm.vfs_cache_pressure=50\n' "$marker" "$swappiness" > "$staged" \
            || ! chmod 0644 "$staged" || ! mv -T -- "$staged" "$sysctl_conf"; then
            rm -f -- "$staged"
            print_warning "Falha ao escrever sysctl; configuracao anterior preservada quando possivel." >&2
            return 1
        fi
    fi

    if [ "$zram_managed" = true ]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        if modprobe -n zram >/dev/null 2>&1; then
            modprobe zram >/dev/null 2>&1 || true
            if systemctl list-unit-files | grep -q 'systemd-zram-setup@'; then
                systemctl start systemd-zram-setup@zram0.service >/dev/null 2>&1 || true
            fi
        fi
    fi
    if [ "$sysctl_managed" = true ]; then
        sysctl --system >/dev/null 2>&1 || true
    fi
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
    local scope="${SYSTEM_TUNING_SCOPE:-none}"
    if [ "$scope" != "host" ]; then
        return 0
    fi

    apply_nofile_limit "$server_user"
    apply_zram_and_sysctl_tuning "$total_ram_mb"
    if is_true "${CRIAS_TUNE_BLOCK_DEVICE:-false}"; then
        if [ -n "${HW_TARGET_DEVICE:-}" ]; then
            apply_block_device_tuning "$HW_TARGET_DEVICE"
        else
            print_warning "Tuning de I/O pulado: nenhum device de bloco confiavel detectado."
        fi
    fi
    if is_true "${CRIAS_TUNE_CPU_GOVERNOR:-false}"; then
        apply_cpupower_tuning "$tier"
    fi
}
