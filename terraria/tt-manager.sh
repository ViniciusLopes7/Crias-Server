#!/bin/bash
# terraria/tt-manager.sh
#
# Stack-specific overrides for Terraria. Shared boilerplate (resolve_self,
# cmd_start/stop/.../backup/monitor/hardware_report, show_help, dispatch) lives
# in shared/lib/manager-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# (EXP-34) O manager pode viver em /usr/local/libexec/crias (producao,
# root:root) ou no repo (desenvolvimento). O diretorio do servidor NUNCA mais
# e usado para resolve-lo — o jogo pode reescrever qualquer coisa la.
SERVER_DIR="${SERVER_DIR:-/opt/terraria-server}"
SERVICE_NAME="terraria"
SERVER_USER="${SERVER_USER:-terraria}"

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
TT_TUNING_LIB="$SHARED_DIR/terraria-tuning.sh"
if [ ! -f "$COMMON_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/common.sh" ]; then
    COMMON_LIB="$SCRIPT_DIR/../shared/lib/common.sh"
fi
if [ ! -f "$HARDWARE_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/hardware-profile.sh" ]; then
    HARDWARE_LIB="$SCRIPT_DIR/../shared/lib/hardware-profile.sh"
fi
if [ ! -f "$TT_TUNING_LIB" ] && [ -f "$SCRIPT_DIR/../shared/lib/terraria-tuning.sh" ]; then
    TT_TUNING_LIB="$SCRIPT_DIR/../shared/lib/terraria-tuning.sh"
fi

# (EXP-34) setup-cron e administrativo (roda como root): vive no libexec,
# nunca no diretorio gravavel do jogo.
CRIS_LIBEXEC_DIR="/usr/local/libexec/crias"
SETUP_CRON_SCRIPT="$CRIS_LIBEXEC_DIR/setup-cron.sh"
if [ ! -x "$SETUP_CRON_SCRIPT" ] && [ -x "$SCRIPT_DIR/setup-cron.sh" ]; then
    SETUP_CRON_SCRIPT="$SCRIPT_DIR/setup-cron.sh"
fi

# (EXP-34/AUDIT-A P3-13) Guarda completa: SELF, libs e o script de setup-cron.
manager_assert_root_safe "$SELF" "$COMMON_LIB" "$HARDWARE_LIB" "$TT_TUNING_LIB" "$SETUP_CRON_SCRIPT"

if [ -d "$SERVER_DIR" ]; then
    if ! id "$SERVER_USER" >/dev/null 2>&1; then
        detected_owner=$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || true) || detected_owner=""
        if [ -n "$detected_owner" ]; then
            SERVER_USER="$detected_owner"
        fi
        unset detected_owner
    fi
fi

BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
CONFIG_FILE="$SERVER_DIR/config/serverconfig.txt"
RUNTIME_ENV="$SERVER_DIR/runtime.env"
TUNING_STATE="$SERVER_DIR/hardware-profile.env"

if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
fi

# log()/warn()/err() centralized in common.sh.

get_cfg() {
    local key="$1"
    local default_value="$2"

    local value
    value="$(config_read_value "$CONFIG_FILE" "$key")"
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    echo "$default_value"
}

# Descrições específicas para o show_help compartilhado (console/health diferem
# entre Minecraft e Terraria).
MANAGER_DESC_CONSOLE="Logs em tempo real (console interativo nao suportado)"
MANAGER_DESC_HEALTH="Verifica se a porta do servidor esta em escuta"

cmd_console() {
    warn "Terraria nao possui console RCON nativo neste manager. Exibindo logs em tempo real."
    cmd_logs
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
    local world_path
    local server_port
    local motd
    local world_name

    forced_tier="${forced_tier^^}"

    manager_need_root "$SELF" "reconfigure-hardware" "$forced_tier"

    if [ ! -f "$COMMON_LIB" ] || [ ! -f "$HARDWARE_LIB" ] || [ ! -f "$TT_TUNING_LIB" ]; then
        err "Bibliotecas de tuning nao encontradas em $SHARED_DIR"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$COMMON_LIB"
    # shellcheck source=/dev/null
    source "$HARDWARE_LIB"
    # shellcheck source=/dev/null
    source "$TT_TUNING_LIB"

    case "$forced_tier" in
        ""|LOW|MID|HIGH) ;;
        *)
            err "Tier invalido: $forced_tier (use LOW, MID ou HIGH)"
            return 1
            ;;
    esac

    detect_hardware_profile "$SERVER_DIR" "$forced_tier"
    compute_terraria_tuning "$HW_TOTAL_RAM_MB" "$HW_CPU_CORES" "$HW_DISK_TYPE" "$HW_TIER"

    write_terraria_runtime_env "$RUNTIME_ENV"

    world_path="$(get_cfg "worldpath" "")"
    server_port="$(get_cfg "port" "")"
    motd="$(get_cfg "motd" "")"
    world_name="$(get_cfg "worldname" "")"
    world_path="${world_path:-$SERVER_DIR/worlds}"
    server_port="${server_port:-7777}"
    motd="${motd:-Servidor Terraria gerenciado por Crias-Server}"
    world_name="${world_name:-world}"

    write_terraria_server_config "$CONFIG_FILE" "$world_path" "$server_port" "$motd" "$world_name"
    write_terraria_tuning_state "$TUNING_STATE"

    echo "Tier detectado: $HW_DETECTED_TIER"
    echo "Tier aplicado: $HW_TIER"
    echo "Max players: $TT_MAX_PLAYERS"
    echo "NPC stream: $TT_NPC_STREAM"

    # Validate SERVER_DIR before chown -R (path traversal prevention).
    if declare -F validate_server_dir >/dev/null 2>&1; then
        if ! validate_server_dir "$SERVER_DIR"; then
            err "SERVER_DIR invalido, nao aplicando chown: $SERVER_DIR"
            return 1
        fi
    fi
    chown -R "${SERVER_USER}:${SERVER_USER}" "$SERVER_DIR"

    warn "Reconfiguracao aplicada em arquivos. Reinicie o servico para aplicar no runtime: sudo systemctl restart $SERVICE_NAME"
}

cmd_health() {
    local server_port

    server_port="$(config_read_value "$CONFIG_FILE" "port")"
    if ! [[ "$server_port" =~ ^[0-9]+$ ]]; then
        server_port=7777
    fi

    if ! port_is_listening "$server_port"; then
        err "Porta $server_port nao esta em escuta."
        return 1
    fi

    log "Health OK: porta $server_port em escuta."
}

manager_dispatch "$@"
