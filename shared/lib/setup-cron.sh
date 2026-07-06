#!/bin/bash
# shared/lib/setup-cron.sh
#
# Unified systemd backup timer setup for any stack.
#
# Usage (from minecraft/setup-cron.sh or terraria/setup-cron.sh):
#
#   #!/bin/bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/.shared/common.sh" 2>/dev/null || source "$SCRIPT_DIR/../shared/lib/common.sh"
#   source "$SCRIPT_DIR/../shared/lib/setup-cron.sh"
#
#   SETUP_CRON_STACK_NAME="minecraft"
#   SETUP_CRON_SERVICE_NAME="minecraft"
#   SETUP_CRON_SERVER_DIR="$SCRIPT_DIR"
#   SETUP_CRON_BACKUP_SCRIPT="$SCRIPT_DIR/backup-cron.sh"
#   setup_cron_run
#
# Variables (with defaults):
#   SETUP_CRON_STACK_NAME       # display name (required)
#   SETUP_CRON_SERVICE_NAME     # systemd service backup depends on (required)
#   SETUP_CRON_SERVER_DIR       # server directory (required)
#   SETUP_CRON_BACKUP_SCRIPT    # backup script (required)
#   SETUP_CRON_SERVER_USER      # optional: auto-detected via stat if empty
#   DRY_RUN                     # default false

# NOTE: do not use `set -u` in sourced libs; caller decides error policy.

# ---------------------------------------------------------------------------
# Detect SERVER_DIR owner if not provided.
# ---------------------------------------------------------------------------
detect_server_user() {
    if [ -n "${SETUP_CRON_SERVER_USER:-}" ]; then
        return 0
    fi

    SETUP_CRON_SERVER_USER=$(stat -c '%U' "$SETUP_CRON_SERVER_DIR" 2>/dev/null || true)
    if [ -z "$SETUP_CRON_SERVER_USER" ] || [ "$SETUP_CRON_SERVER_USER" = "UNKNOWN" ]; then
        SETUP_CRON_SERVER_USER="$(id -un)"
    fi
}

# ---------------------------------------------------------------------------
# Validate interpolated variables for systemd unit files to prevent directive
# injection. Each variable must pass a specific regex; newlines rejected.
# ---------------------------------------------------------------------------
validate_setup_cron_inputs() {
    local var val

    for var in SETUP_CRON_STACK_NAME SETUP_CRON_SERVICE_NAME SETUP_CRON_SERVER_USER; do
        val="${!var:-}"
        if [ -z "$val" ]; then
            continue
        fi
        # User/stack/service names: [a-z_][a-z0-9_-]* only.
        if ! [[ "$val" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            echo -e "${RED}Erro:${NC} $var inválido para systemd unit: '$val' (use [a-z0-9_-])" >&2
            return 1
        fi
    done

    for var in SETUP_CRON_SERVER_DIR SETUP_CRON_BACKUP_SCRIPT SETUP_CRON_BACKUP_SERVICE SETUP_CRON_BACKUP_TIMER; do
        val="${!var:-}"
        if [ -z "$val" ]; then
            continue
        fi
        # Absolute paths: / followed by [a-zA-Z0-9/_.-]; reject newlines,
        # spaces, shell metachars, and chars that break systemd units.
        if [[ "$val" == *$'\n'* ]] || [[ "$val" == *$'\0'* ]] || \
           [[ "$val" == *' '* ]] || [[ "$val" == *';'* ]] || \
           [[ "$val" == *'|'* ]] || [[ "$val" == *'`'* ]] || \
           [[ "$val" == *'$'* ]]; then
            echo -e "${RED}Erro:${NC} $var contém caracteres proibidos para systemd unit: '$val'" >&2
            return 1
        fi
        if ! [[ "$val" =~ ^/[a-zA-Z0-9/_.-]+$ ]]; then
            echo -e "${RED}Erro:${NC} $var deve ser path absoluto com chars [a-zA-Z0-9/_.-]: '$val'" >&2
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Write the backup .service unit.
# ---------------------------------------------------------------------------
write_service_unit() {
    # Validate before interpolating into unit file.
    validate_setup_cron_inputs || return 1

    local target_service="${SETUP_CRON_BACKUP_SERVICE}"
    if is_true "${DRY_RUN:-false}"; then
        target_service="/tmp/$(basename "$SETUP_CRON_BACKUP_SERVICE").dryrun"
        print_step "[DRY_RUN] Será escrito em $target_service (fora de /etc)"
    fi

    cat > "$target_service" <<EOF
[Unit]
Description=${SETUP_CRON_STACK_NAME^} Backup Service
Requires=${SETUP_CRON_SERVICE_NAME}.service
After=${SETUP_CRON_SERVICE_NAME}.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=${SETUP_CRON_SERVER_USER}
Group=${SETUP_CRON_SERVER_USER}
WorkingDirectory=${SETUP_CRON_SERVER_DIR}
ExecStart=${SETUP_CRON_BACKUP_SCRIPT}
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${SETUP_CRON_SERVER_DIR}
UMask=0027
TimeoutStartSec=3600
MemoryMax=1G
MemorySwapMax=0
OOMScoreAdjust=0

EOF
    chmod 0644 "$target_service"
}

# ---------------------------------------------------------------------------
# Write the backup .timer unit.
# ---------------------------------------------------------------------------
write_timer_unit() {
    local desc="$1"
    shift

    local target_timer="${SETUP_CRON_BACKUP_TIMER}"
    if is_true "${DRY_RUN:-false}"; then
        target_timer="/tmp/$(basename "$SETUP_CRON_BACKUP_TIMER").dryrun"
        print_step "[DRY_RUN] Será escrito em $target_timer (fora de /etc)"
    fi

    cat > "$target_timer" <<EOF
[Unit]
Description=${SETUP_CRON_STACK_NAME^} Backup Timer ($desc)

[Timer]
Persistent=true
RandomizedDelaySec=5m
EOF

    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$target_timer"
    done

    cat >> "$target_timer" <<EOF

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$target_timer"
}

# ---------------------------------------------------------------------------
# Remove legacy crontab entries referencing the backup script.
# ---------------------------------------------------------------------------
remove_legacy_cron_entries() {
    local tmp_cron_file
    local has_legacy=false

    if is_true "${DRY_RUN:-false}"; then
        print_step "[DRY_RUN] Simulando remocao de cron (sem alteracoes)"
        return 0
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    if crontab -l 2>/dev/null | grep -Fq "$SETUP_CRON_BACKUP_SCRIPT"; then
        has_legacy=true
    fi

    if [ "$has_legacy" = false ] && [ "$SETUP_CRON_SERVER_USER" != "root" ]; then
        if crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | grep -Fq "$SETUP_CRON_BACKUP_SCRIPT"; then
            has_legacy=true
        fi
    fi

    if [ "$has_legacy" = false ]; then
        return 0
    fi

    tmp_cron_file="$(mktemp)"
    trap 'rm -f "$tmp_cron_file"' RETURN

    if crontab -l 2>/dev/null | grep -Fq "$SETUP_CRON_BACKUP_SCRIPT"; then
        local original_count
        original_count=$(crontab -l 2>/dev/null | wc -l)
        crontab -l 2>/dev/null | grep -Fv "$SETUP_CRON_BACKUP_SCRIPT" > "$tmp_cron_file" || true
        # Only remove crontab entirely if ALL lines were Crias entries.
        if [ -s "$tmp_cron_file" ]; then
            crontab "$tmp_cron_file" >/dev/null 2>&1 || true
        elif [ "$original_count" -le 1 ]; then
            crontab -r >/dev/null 2>&1 || true
        else
            crontab "$tmp_cron_file" >/dev/null 2>&1 || true
        fi
    fi

    if [ "$SETUP_CRON_SERVER_USER" != "root" ] && crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null >/dev/null; then
        if crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | grep -Fq "$SETUP_CRON_BACKUP_SCRIPT"; then
            local original_count_user
            original_count_user=$(crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | wc -l)
            crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | grep -Fv "$SETUP_CRON_BACKUP_SCRIPT" > "$tmp_cron_file" || true
            if [ -s "$tmp_cron_file" ]; then
                crontab -u "$SETUP_CRON_SERVER_USER" "$tmp_cron_file" >/dev/null 2>&1 || true
            elif [ "$original_count_user" -le 1 ]; then
                crontab -u "$SETUP_CRON_SERVER_USER" -r >/dev/null 2>&1 || true
            else
                crontab -u "$SETUP_CRON_SERVER_USER" "$tmp_cron_file" >/dev/null 2>&1 || true
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Entry point: configure backup timer + service.
# ---------------------------------------------------------------------------
setup_cron_run() {
    # Basic validation.
    : "${SETUP_CRON_STACK_NAME:?setup_cron_run requer SETUP_CRON_STACK_NAME}"
    : "${SETUP_CRON_SERVICE_NAME:?setup_cron_run requer SETUP_CRON_SERVICE_NAME}"
    : "${SETUP_CRON_SERVER_DIR:?setup_cron_run requer SETUP_CRON_SERVER_DIR}"
    : "${SETUP_CRON_BACKUP_SCRIPT:?setup_cron_run requer SETUP_CRON_BACKUP_SCRIPT}"

    SETUP_CRON_BACKUP_SERVICE="${SETUP_CRON_BACKUP_SERVICE:-/etc/systemd/system/${SETUP_CRON_SERVICE_NAME}-backup.service}"
    SETUP_CRON_BACKUP_TIMER="${SETUP_CRON_BACKUP_TIMER:-/etc/systemd/system/${SETUP_CRON_SERVICE_NAME}-backup.timer}"

    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE} Configuracao de Backup ${SETUP_CRON_STACK_NAME^}${NC}"
    echo -e "${BLUE}==========================================${NC}"

    if [ ! -f "$SETUP_CRON_BACKUP_SCRIPT" ]; then
        echo -e "${YELLOW}AVISO:${NC} Backup script nao encontrado: $SETUP_CRON_BACKUP_SCRIPT"
        exit 1
    fi

    chmod +x "$SETUP_CRON_BACKUP_SCRIPT"
    detect_server_user

    echo -e "${CYAN}Escolha a frequencia do timer systemd:${NC}"
    echo "1) Diario as 03:00"
    echo "2) Duas vezes por dia (03:00 e 15:00)"
    echo "3) A cada 4 horas"
    echo "4) Semanal (domingo as 03:00)"
    echo "5) Personalizado"
    local choice CUSTOM_LINE DESC TIMER_LINES
    read -r -p "Opcao (1-5): " choice
    case "$choice" in
        1)
            DESC="Diario as 03:00"
            TIMER_LINES=("OnCalendar=*-*-* 03:00:00")
            ;;
        2)
            DESC="Duas vezes por dia"
            TIMER_LINES=("OnCalendar=*-*-* 03:00:00" "OnCalendar=*-*-* 15:00:00")
            ;;
        3)
            DESC="A cada 4 horas"
            TIMER_LINES=("OnBootSec=15m" "OnUnitActiveSec=4h")
            ;;
        4)
            DESC="Semanal domingo as 03:00"
            TIMER_LINES=("OnCalendar=Sun 03:00:00")
            ;;
        5)
            read -r -p "Digite uma linha valida do systemd (OnCalendar=... ou OnUnitActiveSec=...): " CUSTOM_LINE

            # Validate CUSTOM_LINE against systemd directive injection.
            # Only [Timer] section directives accepted.
            if [[ "$CUSTOM_LINE" == *$'\n'* ]] || [[ "$CUSTOM_LINE" == *$'\0'* ]] || \
               [[ "$CUSTOM_LINE" == *';'* ]] || [[ "$CUSTOM_LINE" == *'|'* ]] || \
               [[ "$CUSTOM_LINE" == *'`'* ]] || [[ "$CUSTOM_LINE" == *'$'* ]]; then
                echo -e "${RED}Erro:${NC} CUSTOM_LINE contem caracteres proibidos (newline, null, ;, |, etc)."
                exit 1
            fi
            case "$CUSTOM_LINE" in
                OnActiveSec=*|OnBootSec=*|OnStartupSec=*|OnUnitActiveSec=*|OnUnitInactiveSec=*|\
                OnCalendar=*|OnClockChange=*|OnTimezoneChange=*|AccuracySec=*|RandomizedDelaySec=*|\
                FixedRandomDelay=*|Persistent=*|WakeSystem=*|RemainAfterElapse=*|Unit=*)
                    : # Valid [Timer] directive; accept.
                    ;;
                *)
                    echo -e "${RED}Erro:${NC} CUSTOM_LINE nao e uma diretiva [Timer] valida: $CUSTOM_LINE"
                    echo "Diretivas permitidas: OnCalendar=, OnUnitActiveSec=, OnBootSec=, OnStartupSec=, ..."
                    echo "Consulte: man systemd.timer"
                    exit 1
                    ;;
            esac

            DESC="Personalizado ($CUSTOM_LINE)"
            TIMER_LINES=("$CUSTOM_LINE")
            ;;
        *)
            echo "Opcao invalida."
            exit 1
            ;;
    esac

    write_service_unit
    write_timer_unit "$DESC" "${TIMER_LINES[@]}"
    remove_legacy_cron_entries

    if is_true "${DRY_RUN:-false}"; then
        print_step "[DRY_RUN] Pulando systemctl daemon-reload e habilitacao do timer"
    else
        systemctl daemon-reload
        systemctl enable --now "${SETUP_CRON_SERVICE_NAME}-backup.timer"
    fi

    echo -e "${GREEN}Timer configurado:${NC} $DESC"
    echo "Servico: $SETUP_CRON_BACKUP_SERVICE"
    echo "Timer:   $SETUP_CRON_BACKUP_TIMER"
    echo "Logs:    journalctl -u ${SETUP_CRON_SERVICE_NAME}-backup.service -f"
}
