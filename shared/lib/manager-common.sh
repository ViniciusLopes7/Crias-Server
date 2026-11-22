#!/bin/bash

# Shared helpers for manager scripts (minecraft/terraria).
# Extrai boilerplate comum (resolve_self, cmd_* delegations, monitor) para
# reduzir duplicação entre mc-manager.sh e tt-manager.sh (~95% idênticos).
# Per-stack managers mantêm: stack vars, detected_owner, get_prop/get_cfg,
# cmd_console, cmd_reconfigure_hardware, cmd_health, cmd_setup_cron, cmd_monitor.

# Resolve o caminho real do script (segue symlinks). Shared by mc-manager.sh
# and tt-manager.sh to avoid duplication.
# $1 (opcional): caminho do executavel principal. DENTRO de uma funcao
# definida nesta lib, BASH_SOURCE[0] resolve para a LIB (manager-common.sh),
# nao para o manager que a carregou — por isso o caller deve passar o propio
# caminho (CR-10; fallback: BASH_SOURCE[1], o arquivo que chamou a funcao).
manager_resolve_self() {
    local src="${1:-${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}}"
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

# (EXP-34) Um caminho e seguro para execuicao como root quando: pertence a
# root:root E nao e gravavel por grupo/outros. Retorno: 0=seguro, 1=inseguro.
manager_path_is_root_safe() {
    local path="$1"
    # (AUDIT-A P3-8) Resolve symlinks ANTES do stat: um symlink tem modo
    # sempre 0777 e o stat sem -L rejeitaria qualquer manager invocado via
    # link de conveniencia (ex.: /usr/local/bin/mc-manager). O ALVO e o que
    # importa para a seguranca.
    local resolved="$path"
    if command -v readlink >/dev/null 2>&1; then
        resolved="$(readlink -f "$path" 2>/dev/null || echo "$path")"
    fi
    local stat_out
    stat_out="$(stat -c '%U:%G %a' "$resolved" 2>/dev/null)" || return 1
    local owner="${stat_out%% *}"
    local perms="${stat_out##* }"
    if [ "$owner" != "root:root" ]; then
        return 1
    fi
    # group-write (g+w) ou other-write (o+w) => inseguro.
    if [ "$(( 8#${perms} & 8#022 ))" -ne 0 ]; then
        return 1
    fi
    return 0
}

# (EXP-34) Guarda de escalada: recusa executar como root qualquer manager ou
# lib que seja gravavel por nao-root. O jogo (usuario minecraft/terraria)
# escreve no diretorio do servidor; se os scripts administrativos vivessem
# la, um jogo comprometido ganharia execução arbitrária como root no proximo
# `sudo <manager>`. Bypass explicito para desenvolvimento:
# CRIS_MANAGER_ALLOW_UNSAFE=1 (nao use em producao).
manager_assert_root_safe() {
    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi
    if [ "${CRIS_MANAGER_ALLOW_UNSAFE:-}" = "1" ]; then
        echo "[AVISO] CRIS_MANAGER_ALLOW_UNSAFE=1: verificação de ownership desativada (apenas desenvolvimento)." >&2
        return 0
    fi
    local path
    for path in "$@"; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        if ! manager_path_is_root_safe "$path"; then
            echo "[ERRO] Recusa de execução como root: '$path' não é root:root ou é gravável por grupo/outros." >&2
            echo "[ERRO] Managers/libs administrativos devem vir de /usr/local/libexec/crias (instalador) — nunca do diretório do jogo." >&2
            echo "[ERRO] Desenvolvimento: CRIS_MANAGER_ALLOW_UNSAFE=1 desativa esta verificação." >&2
            return 1
        fi
    done
    return 0
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


# File browsing is administrative in its entrypoint, but the manager itself
# must NEVER grant the full-screen file browser root privileges. Only files
# accessible to the game service account can be modified.
cmd_files() {
    if [ "$#" -gt 1 ]; then
        err "Uso: files [root|mods|config|world|backups|logs]"
        return 2
    fi
    manager_need_root "$SELF" files "$@"
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        err "O gerenciador de arquivos precisa de um terminal interativo (TTY)."
        return 1
    fi
    if ! command -v mc >/dev/null 2>&1; then
        err "Midnight Commander nao instalado. No Hub, escolha 'Instalar gerenciador de arquivos'."
        return 1
    fi
    if ! id "$SERVER_USER" >/dev/null 2>&1 || ! validate_server_dir "$SERVER_DIR" || [ ! -d "$SERVER_DIR" ]; then
        err "Usuario ou diretorio do servidor invalido; recusando explorador."
        return 1
    fi

    local area="root" candidate root_dir resolved level_name
    if [ "$#" -eq 1 ]; then area="$1"; fi
    case "$area" in
        root)
            candidate="$SERVER_DIR"
            ;;
        mods)
            if [ "$SERVICE_NAME" = "terraria" ]; then
                candidate="$SERVER_DIR/Mods"
            else
                candidate="$SERVER_DIR/mods"
            fi
            ;;
        config)
            candidate="$SERVER_DIR/config"
            ;;
        world)
            if [ "$SERVICE_NAME" = "minecraft" ]; then
                level_name="world"
                if [ -r "$SERVER_DIR/server.properties" ]; then
                    level_name="$(awk -F= '$1=="level-name" {print substr($0,index($0,"=")+1); exit}' "$SERVER_DIR/server.properties")"
                    [ -n "$level_name" ] || level_name="world"
                fi
                # level-name is a single directory name, never a path to another
                # location. Custom world names with spaces are supported.
                case "$level_name" in
                    .|..|*/*|*\\*) err "level-name nao e um nome de diretorio seguro."; return 1 ;;
                esac
                candidate="$SERVER_DIR/$level_name"
            else
                candidate="$SERVER_DIR/Worlds"
            fi
            ;;
        backups)
            candidate="$SERVER_DIR/backups"
            ;;
        logs)
            candidate="$SERVER_DIR/logs"
            ;;
        *)
            err "Area desconhecida: $area. Use root|mods|config|world|backups|logs."
            return 2
            ;;
    esac

    if [ ! -d "$candidate" ]; then
        err "Pasta nao encontrada: $candidate. Abra 'Arquivos > Pasta principal' para navegar manualmente."
        return 1
    fi
    root_dir="$(realpath -e -- "$SERVER_DIR")" || return 1
    resolved="$(realpath -e -- "$candidate")" || return 1
    # Do not follow a shortcut symlink pointing outside the game directory.
    case "$resolved" in
        "$root_dir"|"$root_dir"/*) ;;
        *) err "Atalho fora da pasta do servidor: $candidate"; return 1 ;;
    esac

    echo "[Arquivos] Abrindo $resolved como $SERVER_USER, sem privilegios de root."
    # mc is an interactive file manager that can launch a shell/editor;
    # invoking it as root would give unbounded write access to the host.
    sudo -u "$SERVER_USER" -- env HOME="$SERVER_DIR" mc "$resolved"
}

cmd_setup_files() {
    if [ "$#" -ne 0 ]; then
        err "Uso: setup-files (sem argumentos)"
        return 2
    fi
    manager_need_root "$SELF" setup-files
    if command -v mc >/dev/null 2>&1; then
        log "Midnight Commander ja disponivel."
        return 0
    fi
    if ! command -v pacman >/dev/null 2>&1; then
        err "pacman nao encontrado; instale 'mc' manualmente."
        return 1
    fi
    # Package from the official Arch repository; only at user's request.
    pacman -S --needed --noconfirm mc || {
        err "Falha na instalacao do Midnight Commander."
        return 1
    }
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
            logs)                       desc="${MANAGER_DESC_LOGS:-Tail dos logs (journalctl)}" ;;
            console)                    desc="${MANAGER_DESC_CONSOLE:-Console do servico}" ;;
            setup-console)              desc="Instala mcrcon e configura RCON (sem reiniciar Minecraft)" ;;
            monitor)                    desc="Ferramentas de monitoramento: btop/htop/ncdu (cpu|disk|net)" ;;
            files)                      desc="Explora arquivos do servidor com Midnight Commander (usuario do jogo)" ;;
            setup-files)                desc="Instala Midnight Commander do repositorio Arch sob demanda" ;;
            voicechat)                  desc="Simple Voice Chat: status|set-port|edit|network" ;;
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
        files) shift; cmd_files "$@" ;;
        setup-files) shift; cmd_setup_files "$@" ;;
        voicechat) shift; if declare -F cmd_voicechat >/dev/null; then cmd_voicechat "$@"; else err "Voice Chat nao suportado neste stack."; return 2; fi ;;
        setup-console) shift; cmd_setup_console "$@" ;;
        monitor) shift; cmd_monitor "$@" ;;
        health) shift; cmd_health "$@" ;;
        backup) shift; cmd_backup "$@" ;;
        setup-cron) shift; cmd_setup_cron "$@" ;;
        reconfigure-hardware) shift; cmd_reconfigure_hardware "${1:-}" ;;
        hardware-report) shift; cmd_hardware_report "$@" ;;
        *) manager_show_help; exit 1 ;;
    esac
}
