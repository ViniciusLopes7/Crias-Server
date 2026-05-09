#!/bin/bash
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
BACKUP_SERVICE="/etc/systemd/system/minecraft-backup.service"
BACKUP_TIMER="/etc/systemd/system/minecraft-backup.timer"
DRY_RUN="${DRY_RUN:-false}"
SERVER_USER="${SERVER_USER:-}"

# Reuse shared ANSI color definitions when available (installed stacks ship it in .shared).
COMMON_LIB="$SERVER_DIR/.shared/common.sh"
if [ -f "$COMMON_LIB" ]; then
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
else
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
fi

detect_server_user() {
    if [ -n "$SERVER_USER" ]; then
        return 0
    fi

    SERVER_USER=$(stat -c '%U' "$SERVER_DIR" 2>/dev/null || true)
    if [ -z "$SERVER_USER" ] || [ "$SERVER_USER" = "UNKNOWN" ]; then
        SERVER_USER="$(id -un)"
    fi
}

write_service_unit() {
    local target_service="$BACKUP_SERVICE"
    if [ "$DRY_RUN" = "true" ]; then
        target_service="/tmp/$(basename "$BACKUP_SERVICE").dryrun"
        echo "[DRY_RUN] Registrando unidade em $target_service (nao sera escrita em /etc em modo DRY_RUN)"
    fi

    cat > "$target_service" <<EOF
[Unit]
Description=Minecraft Backup Service
Requires=minecraft.service
After=minecraft.service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=$SERVER_USER
Group=$SERVER_USER
WorkingDirectory=$SERVER_DIR
ExecStart=$BACKUP_SCRIPT
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=$SERVER_DIR
UMask=0027
TimeoutStartSec=3600
MemoryMax=1G
MemorySwapMax=0
OOMScoreAdjust=0

EOF
    chmod 0644 "$target_service"
}

write_timer_unit() {
    local desc="$1"
    shift

    local target_timer="$BACKUP_TIMER"
    if [ "$DRY_RUN" = "true" ]; then
        target_timer="/tmp/$(basename "$BACKUP_TIMER").dryrun"
        echo "[DRY_RUN] Registrando timer em $target_timer (nao sera escrita em /etc em modo DRY_RUN)"
    fi

    cat > "$target_timer" <<EOF
[Unit]
Description=Minecraft Backup Timer ($desc)

[Timer]
Persistent=true
RandomizedDelaySec=5m
EOF

    for line in "$@"; do
        printf '%s\n' "$line" >> "$target_timer"
    done

    cat >> "$target_timer" <<EOF

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$target_timer"
}

remove_legacy_cron_entries() {
    local tmp_cron_file
    local has_legacy=false

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY_RUN] Simulando remocao de cron (sem alteracoes)"
        return 0
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    if crontab -l 2>/dev/null | grep -Fq "$BACKUP_SCRIPT"; then
        has_legacy=true
    fi

    if [ "$has_legacy" = false ] && [ "$SERVER_USER" != "root" ]; then
        if crontab -u "$SERVER_USER" -l 2>/dev/null | grep -Fq "$BACKUP_SCRIPT"; then
            has_legacy=true
        fi
    fi

    if [ "$has_legacy" = false ]; then
        return 0
    fi

    tmp_cron_file="$(mktemp)"
    trap 'rm -f "$tmp_cron_file"' RETURN

    if crontab -l 2>/dev/null | grep -Fq "$BACKUP_SCRIPT"; then
        crontab -l 2>/dev/null | grep -Fv "$BACKUP_SCRIPT" > "$tmp_cron_file" || true
        if [ -s "$tmp_cron_file" ]; then
            crontab "$tmp_cron_file" >/dev/null 2>&1 || true
        else
            crontab -r >/dev/null 2>&1 || true
        fi
    fi

    if [ "$SERVER_USER" != "root" ] && crontab -u "$SERVER_USER" -l 2>/dev/null >/dev/null; then
        if crontab -u "$SERVER_USER" -l 2>/dev/null | grep -Fq "$BACKUP_SCRIPT"; then
            crontab -u "$SERVER_USER" -l 2>/dev/null | grep -Fv "$BACKUP_SCRIPT" > "$tmp_cron_file" || true
            if [ -s "$tmp_cron_file" ]; then
                crontab -u "$SERVER_USER" "$tmp_cron_file" >/dev/null 2>&1 || true
            else
                crontab -u "$SERVER_USER" -r >/dev/null 2>&1 || true
            fi
        fi
    fi
}

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE} Configuracao de Backup Minecraft${NC}"
echo -e "${BLUE}==========================================${NC}"

if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo -e "${YELLOW}AVISO:${NC} Backup script nao encontrado: $BACKUP_SCRIPT"
    exit 1
fi

chmod +x "$BACKUP_SCRIPT"
detect_server_user

echo -e "${CYAN}Escolha a frequencia do timer systemd:${NC}"
echo "1) Diario as 03:00"
echo "2) Duas vezes por dia (03:00 e 15:00)"
echo "3) A cada 4 horas"
echo "4) Semanal (domingo as 03:00)"
echo "5) Personalizado"
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

if [ "$DRY_RUN" = "true" ]; then
    echo "[DRY_RUN] Pulando systemctl daemon-reload e habilitacao do timer em modo DRY_RUN"
else
    systemctl daemon-reload
    systemctl enable --now minecraft-backup.timer
fi

echo -e "${GREEN}Timer configurado:${NC} $DESC"
echo "Servico: $BACKUP_SERVICE"
echo "Timer:   $BACKUP_TIMER"
echo "Logs:    journalctl -u minecraft-backup.service -f"
