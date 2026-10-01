#!/bin/bash

# Shared helpers for manager scripts (minecraft/terraria).
# Extrai boilerplate comum (resolve_self, cmd_* delegations, monitor) para
# reduzir duplicação entre mc-manager.sh e tt-manager.sh (~95% idênticos).
# Per-stack managers mantêm: stack vars, detected_owner, get_prop/get_cfg,
# cmd_console, cmd_reconfigure_hardware, cmd_health, cmd_setup_cron, cmd_monitor.

# Resolve o caminho real do script (segue symlinks). Shared by mc-manager.sh
# and tt-manager.sh to avoid duplication.
manager_resolve_self() {
    local src="${BASH_SOURCE[0]}"
    local resolved=""
    if command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f "$src" 2>/dev/null || true)"
    fi
    if [ -z "$resolved" ] && command -v realpath >/dev/null 2>&1; then
        resolved="$(realpath "$src" 2>/dev/null || true)"
    fi
    if [ -n "$resolved" ]; then
        echo "$resolved"
    else
        echo "$src"
    fi
}

manager_need_root() {
    local self_path="$1"
    shift || true

    if [ "$(id -u)" -ne 0 ]; then
        exec sudo "$self_path" "$@"
    fi
}

manager_run_as_server_user() {
    local server_user="$1"
    shift

    if [ "$(id -u)" -eq 0 ] && id "$server_user" >/dev/null 2>&1; then
        sudo -u "$server_user" -- "$@"
    else
        "$@"
    fi
}

manager_cmd_start() {
    local service_name="$1"
    systemctl start "$service_name"
}

manager_cmd_stop() {
    local service_name="$1"
    systemctl stop "$service_name"
}

manager_cmd_restart() {
    local service_name="$1"
    systemctl restart "$service_name"
}

manager_cmd_status() {
    local service_name="$1"
    systemctl status "$service_name" --no-pager || true

    if command -v sensors >/dev/null 2>&1; then
        printf '\n[Hardware]\n'
        sensors 2>/dev/null || true
    fi
}

manager_cmd_logs() {
    local service_name="$1"
    journalctl -u "$service_name" -f
}

# ---------------------------------------------------------------------------
# Monitor: lança ferramentas de monitoramento (btop/htop/ncdu/iotop-c).
# Tools pre-installed on the ISO (packages.x86_64).
# Uso: cmd_monitor [cpu|disk|net]  (default = cpu)
# ---------------------------------------------------------------------------
manager_cmd_monitor() {
    local kind="${1:-cpu}"
    case "$kind" in
        cpu|"")
            if command -v btop >/dev/null 2>&1; then
                exec btop
            elif command -v htop >/dev/null 2>&1; then
                exec htop
            else
                echo "[ERRO] Nem btop nem htop instalados. Instale: pacman -S btop" >&2
                return 1
            fi
            ;;
        disk)
            if command -v ncdu >/dev/null 2>&1; then
                local target="${SERVER_DIR:-/}"
                exec ncdu "$target"
            else
                echo "[ERRO] ncdu não instalado. Instale: pacman -S ncdu" >&2
                return 1
            fi
            ;;
        net)
            if command -v btop >/dev/null 2>&1; then
                exec btop
            elif command -v iotop-c >/dev/null 2>&1; then
                exec iotop-c
            else
                echo "[ERRO] Nem btop nem iotop-c instalados." >&2
                return 1
            fi
            ;;
        *)
            echo "Uso: monitor [cpu|disk|net]" >&2
            echo "  cpu  (default): btop ou htop — CPU/RAM/processos" >&2
            echo "  disk: ncdu — explorador de uso de disco" >&2
            echo "  net:  btop (aba network) ou iotop-c — I/O por processo" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Shared cmd_* wrappers (delegations). Per-stack managers podem sobrescrever
# se precisarem de comportamento específico (ex.: cmd_console, cmd_health).
# ---------------------------------------------------------------------------
cmd_start() { manager_cmd_start "$SERVICE_NAME"; }
cmd_stop() { manager_cmd_stop "$SERVICE_NAME"; }
cmd_restart() { manager_cmd_restart "$SERVICE_NAME"; }
cmd_status() { manager_cmd_status "$SERVICE_NAME"; }
cmd_logs() { manager_cmd_logs "$SERVICE_NAME"; }
cmd_monitor() { manager_cmd_monitor "$@"; }

cmd_backup() {
    if [ ! -x "$BACKUP_SCRIPT" ]; then
        err "Script de backup nao encontrado: $BACKUP_SCRIPT"
        return 1
    fi
    manager_run_as_server_user "$SERVER_USER" "$BACKUP_SCRIPT"
}

cmd_hardware_report() {
    if [ -f "$TUNING_STATE" ]; then
        cat "$TUNING_STATE"
    else
        warn "Arquivo de estado nao encontrado: $TUNING_STATE"
    fi
}

# ---------------------------------------------------------------------------
# Dynamic help. Lista cmd_* functions via declare -F e mapeia para descrição.
# Per-stack managers setam MANAGER_DESC_CONSOLE e MANAGER_DESC_HEALTH antes de
# chamar manager_dispatch (as descrições de console/health diferem entre stacks).
# ---------------------------------------------------------------------------
manager_show_help() {
    cat << EOF
Uso: $0 <comando>

Comandos disponiveis:
EOF
    local fn
    while IFS= read -r fn; do
        local cmd="${fn#cmd_}"
        local desc=""
        case "$cmd" in
            start)                      desc="Inicia o servico (systemd)" ;;
            stop)                       desc="Para o servico (systemd)" ;;
            restart)                    desc="Reinicia o servico (systemd)" ;;
            status)                     desc="Mostra status (systemd)" ;;
            logs)                       desc="Tail dos logs (journalctl)" ;;
            console)                    desc="${MANAGER_DESC_CONSOLE:-Console do servico}" ;;
            monitor)                    desc="Ferramentas de monitoramento: btop/htop/ncdu (cpu|disk|net)" ;;
            health)                     desc="${MANAGER_DESC_HEALTH:-Health check do servidor}" ;;
            backup)                     desc="Executa backup imediato" ;;
            setup-cron)                 desc="Configura timer systemd de backup" ;;
            reconfigure-hardware)       desc="Recalcula tuning (TIER: LOW|MID|HIGH ou vazio)" ;;
            hardware-report)            desc="Exibe perfil/tuning aplicado" ;;
        esac
        printf '  %-30s %s\n' "$cmd" "$desc"
    done < <(declare -F | awk '{print $3}' | grep -E '^cmd_' | sort)
}

# ---------------------------------------------------------------------------
# Case dispatch. Per-stack managers chamam manager_dispatch "$@" no final,
# após definir suas cmd_* específicas (cmd_console, cmd_health, cmd_setup_cron,
# cmd_reconfigure_hardware). As shared cmd_* (start/stop/.../backup/monitor/
# hardware_report) já estão definidas aqui.
# ---------------------------------------------------------------------------
manager_dispatch() {
    case "${1:-}" in
        start) shift; cmd_start "$@" ;;
        stop) shift; cmd_stop "$@" ;;
        restart) shift; cmd_restart "$@" ;;
        status) shift; cmd_status "$@" ;;
        logs) shift; cmd_logs "$@" ;;
        console) shift; cmd_console "$@" ;;
        monitor) shift; cmd_monitor "$@" ;;
        health) shift; cmd_health "$@" ;;
        backup) shift; cmd_backup "$@" ;;
        setup-cron) shift; cmd_setup_cron "$@" ;;
        reconfigure-hardware) shift; cmd_reconfigure_hardware "${1:-}" ;;
        hardware-report) shift; cmd_hardware_report "$@" ;;
        *) manager_show_help; exit 1 ;;
    esac
}
