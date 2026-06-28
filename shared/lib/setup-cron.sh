#!/bin/bash
# shared/lib/setup-cron.sh
#
# Configuração unificada de timer systemd de backup para qualquer stack.
# Substitui minecraft/setup-cron.sh e terraria/setup-cron.sh que eram 99%
# idênticos (item A2 do plano).
#
# Como usar (a partir de minecraft/setup-cron.sh ou terraria/setup-cron.sh):
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
# Variáveis (com defaults):
#   SETUP_CRON_STACK_NAME       # exibido em mensagens (obrigatório)
#   SETUP_CRON_SERVICE_NAME     # serviço systemd que o backup depende (obrigatório)
#   SETUP_CRON_SERVER_DIR       # diretório do servidor (obrigatório)
#   SETUP_CRON_BACKUP_SCRIPT    # script de backup (obrigatório)
#   SETUP_CRON_SERVER_USER      # opcional: auto-detectado via stat se vazio
#   DRY_RUN                     # default false

# NOTA: não usar `set -u` em libs sourced — caller decide política de erro.

# ---------------------------------------------------------------------------
# Detecta usuário dono do SERVER_DIR se não fornecido.
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
# Escreve a unit .service do backup.
# ---------------------------------------------------------------------------
write_service_unit() {
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
# Escreve a unit .timer do backup.
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
# Remove entradas legacy de crontab que referenciem o backup-script.
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
        crontab -l 2>/dev/null | grep -Fv "$SETUP_CRON_BACKUP_SCRIPT" > "$tmp_cron_file" || true
        if [ -s "$tmp_cron_file" ]; then
            crontab "$tmp_cron_file" >/dev/null 2>&1 || true
        else
            crontab -r >/dev/null 2>&1 || true
        fi
    fi

    if [ "$SETUP_CRON_SERVER_USER" != "root" ] && crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null >/dev/null; then
        if crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | grep -Fq "$SETUP_CRON_BACKUP_SCRIPT"; then
            crontab -u "$SETUP_CRON_SERVER_USER" -l 2>/dev/null | grep -Fv "$SETUP_CRON_BACKUP_SCRIPT" > "$tmp_cron_file" || true
            if [ -s "$tmp_cron_file" ]; then
                crontab -u "$SETUP_CRON_SERVER_USER" "$tmp_cron_file" >/dev/null 2>&1 || true
            else
                crontab -u "$SETUP_CRON_SERVER_USER" -r >/dev/null 2>&1 || true
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Ponto de entrada: configura timer + service do backup.
# ---------------------------------------------------------------------------
setup_cron_run() {
    # Validação básica.
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
