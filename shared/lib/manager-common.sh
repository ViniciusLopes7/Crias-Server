#!/bin/bash

# Shared helpers for manager scripts (minecraft/terraria).

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
