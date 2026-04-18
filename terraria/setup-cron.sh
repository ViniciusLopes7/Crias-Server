#!/bin/bash

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SERVER_DIR/backup-cron.sh"
LOG_FILE="/var/log/terraria-backup.log"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE} Configuracao de Backup Terraria${NC}"
echo -e "${BLUE}==========================================${NC}"

if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo -e "${YELLOW}AVISO:${NC} Backup script nao encontrado: $BACKUP_SCRIPT"
    exit 1
fi

chmod +x "$BACKUP_SCRIPT"

echo -e "${CYAN}Escolha a frequencia:${NC}"
echo "1) Diario as 03:00"
echo "2) Duas vezes por dia (03:00 e 15:00)"
echo "3) A cada 4 horas"
echo "4) Semanal (domingo as 03:00)"
echo "5) Personalizado"
read -r -p "Opcao (1-5): " choice

case "$choice" in
    1) CRON_EXPR="0 3 * * *" ; DESC="Diario as 03:00" ;;
    2) CRON_EXPR="0 3,15 * * *" ; DESC="Duas vezes por dia" ;;
    3) CRON_EXPR="0 */4 * * *" ; DESC="A cada 4 horas" ;;
    4) CRON_EXPR="0 3 * * 0" ; DESC="Semanal domingo as 03:00" ;;
    5)
        read -r -p "Digite a expressao cron: " CRON_EXPR
        DESC="Personalizado ($CRON_EXPR)"
        ;;
    *)
        echo "Opcao invalida."
        exit 1
        ;;
esac

CRON_LINE="$CRON_EXPR $BACKUP_SCRIPT >> $LOG_FILE 2>&1"

( crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_LINE" ) | crontab -

echo -e "${GREEN}Backup configurado:${NC} $DESC"
echo "Log: $LOG_FILE"
