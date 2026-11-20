#!/bin/bash
# minecraft/mc-manager.sh
#
# Stack-specific overrides for Minecraft. Shared boilerplate (resolve_self,
# cmd_start/stop/.../backup/monitor/hardware_report, show_help, dispatch) lives
# in shared/lib/manager-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (EXP-34) O manager pode viver em /usr/local/libexec/crias (producao,
# root:root) ou no repo (desenvolvimento). O diretorio do servidor NUNCA mais
# e usado para resolve-lo — o jogo pode reescrever qualquer coisa la.
SERVER_DIR="${SERVER_DIR:-/opt/minecraft-server}"
SERVICE_NAME="minecraft"
SERVER_USER="${SERVER_USER:-minecraft}"

# (EXP-34) Resolucao das libs administrativas: libexec (producao) ->
# .shared do servidor (legado) -> repo (desenvolvimento).
CRIS_LIBEXEC_LIB_DIR="/usr/local/libexec/crias/lib"
if [ -f "$CRIS_LIBEXEC_LIB_DIR/manager-common.sh" ]; then
    MANAGER_COMMON_LIB="$CRIS_LIBEXEC_LIB_DIR/manager-common.sh"
elif [ -f "$SERVER_DIR/.shared/manager-common.sh" ]; then
    MANAGER_COMMON_LIB="$SERVER_DIR/.shared/manager-common.sh"
elif [ -f "$SCRIPT_DIR/../shared/lib/manager-common.sh" ]; then
    MANAGER_COMMON_LIB="$SCRIPT_DIR/../shared/lib/manager-common.sh"
else
    echo "[ERRO] Biblioteca manager-common nao encontrada (libexec/.shared/repo)." >&2
    exit 1
fi

# (EXP-34) Pre-check INLINE antes do primeiro source: executando como root,
# o manager e a lib nao podem ser gravaveis por nao-root (o jogo reescreve o
# diretorio do servidor; `sudo <manager>` viraria execução arbitrária root).
if [ "$(id -u)" -eq 0 ] && [ "${CRIS_MANAGER_ALLOW_UNSAFE:-}" != "1" ]; then
    for _pre_check_path in "${BASH_SOURCE[0]}" "$MANAGER_COMMON_LIB"; do
        if [ -e "$_pre_check_path" ]; then
            _pre_stat="$(stat -c '%U:%G %a' "$_pre_check_path" 2>/dev/null)" || {
                echo "[ERRO] Recusa root: stat falhou em $_pre_check_path" >&2; exit 1;
            }
            if [ "${_pre_stat%% *}" != "root:root" ] || [ "$(( 8#${_pre_stat##* } & 8#022 ))" -ne 0 ]; then
                echo "[ERRO] Recusa de execução como root: '$_pre_check_path' não é root:root ou é gravável por grupo/outros (EXP-34)." >&2
                echo "[ERRO] Managers administrativos devem vir de /usr/local/libexec/crias. Desenvolvimento: CRIS_MANAGER_ALLOW_UNSAFE=1." >&2
                exit 1
            fi
        fi
    done
    unset _pre_check_path _pre_stat
fi

# shellcheck source=/dev/null
source "$MANAGER_COMMON_LIB"

# SELF precisa ser setado após source do manager-common (que define manager_resolve_self).
# BASH_SOURCE[0] no top-level do manager = o PROPRIO manager (na funcao da lib
# seria a lib — CR-10); passado explicitamente para a auto-elevacao reinovocar
# o manager certo.
SELF="$(manager_resolve_self "${BASH_SOURCE[0]}")"

# (EXP-34) Libs restantes seguem a MESMA resolucao (libexec -> .shared -> repo).
if [ -f "$CRIS_LIBEXEC_LIB_DIR/common.sh" ]; then
    SHARED_DIR="$CRIS_LIBEXEC_LIB_DIR"
else
    SHARED_DIR="$SERVER_DIR/.shared"
fi
COMMON_LIB="$SHARED_DIR/common.sh"
HARDWARE_LIB="$SHARED_DIR/hardware-profile.sh"
MC_TUNING_LIB="$SHARED_DIR/minecraft-tuning.sh"
if [ ! -f "$COMMON_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/common.sh" ]; then
    COMMON_LIB="$SCRIPT_DIR/../shared/lib/common.sh"
fi
if [ ! -f "$HARDWARE_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/hardware-profile.sh" ]; then
    HARDWARE_LIB="$SCRIPT_DIR/../shared/lib/hardware-profile.sh"
fi
if [ ! -f "$MC_TUNING_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/minecraft-tuning.sh" ]; then
    MC_TUNING_LIB="$SCRIPT_DIR/../shared/lib/minecraft-tuning.sh"
fi

# (EXP-34) setup-cron e administrativo (roda como root): vive no libexec,
# nunca no diretorio gravavel do jogo.
CRIS_LIBEXEC_DIR="/usr/local/libexec/crias"
SETUP_CRON_SCRIPT="$CRIS_LIBEXEC_DIR/setup-cron.sh"
if [ ! -x "$SETUP_CRON_SCRIPT" ] && [ -x "$SCRIPT_DIR/setup-cron.sh" ]; then
    SETUP_CRON_SCRIPT="$SCRIPT_DIR/setup-cron.sh"
fi

# (EXP-34/AUDIT-A P3-13) Guarda completa: SELF, libs e o script de setup-cron
# (tambem executado como root pelo manager) — recusa root em caminhos
# gravaveis por nao-root.
manager_assert_root_safe "$SELF" "$COMMON_LIB" "$HARDWARE_LIB" "$MC_TUNING_LIB" "$SETUP_CRON_SCRIPT"

if [ -d "$SERVER_DIR" ]; then
    if ! id "$SERVER_USER" >/dev/null 2>&1; then
        # detected_owner is temporary; script is top-level (no `local` in global scope).
        detected_owner=$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || true) || detected_owner=""
        if [ -n "$detected_owner" ]; then
            SERVER_USER="$detected_owner"
        fi
        unset detected_owner
    fi
fi

BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
PROPS_FILE="$SERVER_DIR/server.properties"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
TUNING_STATE="$SERVER_DIR/hardware-profile.env"

if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
fi

# log()/warn()/err() centralized in common.sh. Do not redefine locally.

get_prop() {
    local key="$1"
    local default_value="$2"

    local value
    value="$(config_read_value "$PROPS_FILE" "$key")"
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    echo "$default_value"
}

# Descrições específicas para o show_help compartilhado (console/health diferem
# entre Minecraft e Terraria).
MANAGER_DESC_CONSOLE="Console interativo via RCON (fallback para logs)"
MANAGER_DESC_HEALTH="Verifica porta e RCON do servidor"
MANAGER_DESC_LOGS="Logs: follow (padrao), recent, boot, alerts"

# Apresenta logs com timestamps completos. Nao confundir linhas WARN
# impressas pelo Java no stdout com a prioridade do journal: -p warning
# sozinho perde muitos avisos do Forge/Fabric.
cmd_logs() {
    local mode="${1:-follow}"
    if [ "$#" -gt 1 ]; then
        echo "Uso: logs [follow|recent|boot|alerts]" >&2
        return 2
    fi
    case "$mode" in
        follow)
            echo "[Minecraft] Acompanhando as ultimas 80 linhas (Ctrl+C para sair)..."
            journalctl -u "$SERVICE_NAME" -n 80 -f -o short-iso
            ;;
        recent)
            echo "[Minecraft] Ultimas 150 linhas completas:"
            journalctl -u "$SERVICE_NAME" -n 150 --no-pager -o short-iso
            ;;
        boot)
            echo "[Minecraft] Ultimas 200 linhas deste boot:"
            journalctl -u "$SERVICE_NAME" -b -n 200 --no-pager -o short-iso
            ;;
        alerts)
            echo "[Minecraft] Linhas com WARN/ERROR/Exception/OOM das ultimas 400 mensagens."
            echo "[Minecraft] Filtro textual, nao substitui a leitura do log completo."
            local journal_output
            journal_output="$(journalctl -u "$SERVICE_NAME" -n 400 --no-pager -o short-iso)" || return 1
            if ! printf "%s\n" "$journal_output" | grep -Ei "WARN|ERROR|Exception|OutOfMemory|oom-kill|Killed process|timed out|Cannot start"; then
                echo "[Minecraft] Nenhuma linha correspondente no intervalo pesquisado."
            fi
            ;;
        *)
            echo "Uso: logs [follow|recent|boot|alerts]" >&2
            return 2
            ;;
    esac
}

cmd_console() {
    local rcon_pass
    local rcon_port

    if ! command -v mcrcon >/dev/null 2>&1; then
        warn "Console interativo requer mcrcon. Instale via AUR (ex: yay -S mcrcon) ou construa a partir do PKGBUILD do AUR."
        cmd_logs
        return 0
    fi

    rcon_pass="$(get_prop "rcon.password" "")"
    rcon_port="$(get_prop "rcon.port" "25575")"

    if [ -z "$rcon_pass" ]; then
        warn "RCON nao configurado em $PROPS_FILE (rcon.password)."
        cmd_logs
        return 0
    fi

    if ! [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        rcon_port=25575
    fi

    MCRCON_PASS="$rcon_pass" exec mcrcon -H localhost -P "$rcon_port"
}

cmd_setup_cron() {
    if [ ! -x "$SETUP_CRON_SCRIPT" ]; then
        err "Script de setup-cron nao encontrado: $SETUP_CRON_SCRIPT"
        return 1
    fi
    manager_need_root "$SELF" "setup-cron" "$@"
    SERVER_USER="$SERVER_USER" "$SETUP_CRON_SCRIPT"
}

cmd_reconfigure_hardware() {
    local forced_tier="${1:-}"
    local server_port online_mode motd
    forced_tier="${forced_tier^^}"

    manager_need_root "$SELF" "reconfigure-hardware" "$forced_tier"

    if [ ! -f "$HARDWARE_LIB" ] || [ ! -f "$MC_TUNING_LIB" ]; then
        err "Bibliotecas de tuning nao encontradas em $SHARED_DIR"
        return 1
    fi

    case "$forced_tier" in
        ""|LOW|MID|HIGH) ;;
        *)
            err "Tier invalido: $forced_tier (use LOW, MID ou HIGH)"
            return 1
            ;;
    esac

    # shellcheck source=/dev/null
    source "$HARDWARE_LIB"
    # shellcheck source=/dev/null
    source "$MC_TUNING_LIB"

    # Nao reduza/aumente limites em processo ativo: pare o Minecraft antes
    # de reconciliar heap, MemoryMax e demais arquivos.
    local unit_state
    unit_state="$(systemctl show "$SERVICE_NAME.service" -p ActiveState --value 2>/dev/null || true)"
    case "$unit_state" in
        inactive|failed) ;;
        *)
            err "Minecraft deve estar completamente parado para recalibrar: estado=${unit_state:-desconhecido}. Execute sudo systemctl stop $SERVICE_NAME"
            return 1
            ;;
    esac
    if ! systemctl cat "$SERVICE_NAME.service" >/dev/null 2>&1; then
        err "A unidade $SERVICE_NAME.service nao existe. Complete a instalacao antes de recalibrar."
        return 1
    fi
    if ! validate_server_dir "$SERVER_DIR"; then
        err "Diretorio de servidor invalido: $SERVER_DIR"
        return 1
    fi
    for managed_file in "$RUNTIME_ENV" "$PROPS_FILE" "$TUNING_STATE"; do
        if [ -L "$managed_file" ]; then
            err "Arquivo administrativo e link simbolico: $managed_file"
            return 1
        fi
    done

    detect_hardware_profile "$SERVER_DIR" "$forced_tier"
    compute_minecraft_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER" || return 1

    # O systemd recebe a mesma cota de memoria calculada para runtime.env.
    # O helper valida e reverte o drop-in se daemon-reload/verify falhar.
    write_minecraft_systemd_memory_limit "$MC_SERVICE_MEMORY_MAX_MB" || return 1
    write_minecraft_runtime_env "$RUNTIME_ENV"

    server_port="$(config_read_value "$PROPS_FILE" "server-port")"
    online_mode="$(config_read_value "$PROPS_FILE" "online-mode")"
    motd="$(config_read_value "$PROPS_FILE" "motd")"
    server_port="${server_port:-25565}"
    online_mode="${online_mode:-false}"
    motd="${motd:-Servidor Minecraft}"

    write_minecraft_server_properties "$PROPS_FILE" "$server_port" "$online_mode" "$motd"
    write_minecraft_tuning_state "$TUNING_STATE"

    echo "Tier detectado: $HW_DETECTED_TIER"
    echo "Tier aplicado: $HW_TIER"
    echo "Heap aplicado: $MC_MIN_RAM -> $MC_MAX_RAM"
    echo "View/Simulation: $MC_VIEW_DISTANCE / $MC_SIMULATION_DISTANCE"
    echo "Max players: $MC_MAX_PLAYERS"

    # Nunca varra os mundos com chown -R apenas para editar tres configs.
    chown "${SERVER_USER}:${SERVER_USER}" "$RUNTIME_ENV" "$PROPS_FILE" "$TUNING_STATE"

    echo "MemoryMax aplicado no systemd: ${MC_SERVICE_MEMORY_MAX_MB} MB"
    echo "Reserva para SO: ${MC_HOST_RESERVE_MB} MB | memoria JVM nativa: ${MC_NATIVE_OVERHEAD_MB} MB"
    warn "Heap e MemoryMax sincronizados. Servico continua parado; confira os limites e execute: sudo systemctl reset-failed $SERVICE_NAME; sudo systemctl start $SERVICE_NAME"
}

cmd_health() {
    local server_port
    local rcon_pass
    local rcon_port

    server_port="$(get_prop "server-port" "25565")"
    if ! [[ "$server_port" =~ ^[0-9]+$ ]]; then
        server_port=25565
    fi

    if ! port_is_listening "$server_port"; then
        err "Porta $server_port nao esta em escuta."
        return 1
    fi

    rcon_pass="$(get_prop "rcon.password" "")"
    rcon_port="$(get_prop "rcon.port" "25575")"
    if ! [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        rcon_port=25575
    fi

    if [ -n "$rcon_pass" ] && command -v mcrcon >/dev/null 2>&1; then
        if MCRCON_PASS="$rcon_pass" timeout 10 mcrcon -H localhost -P "$rcon_port" "list" >/dev/null 2>&1; then
            log "Health OK: porta $server_port e RCON responderam."
            return 0
        fi

        err "Porta $server_port em escuta, mas RCON nao respondeu."
        return 1
    fi

    warn "Health limitado a porta em escuta; RCON indisponivel para verificacao."
    return 0
}

manager_dispatch "$@"
