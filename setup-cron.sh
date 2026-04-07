#!/bin/bash

# ============================================
# Setup Cron para Backups Automáticos
# ============================================

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}  Configuração de Backup Automático${NC}"
echo -e "${BLUE}==========================================${NC}"
echo ""

# Verificar se script de backup existe
if [ ! -f "/opt/minecraft-server/backup-cron.sh" ]; then
    echo -e "${YELLOW}AVISO:${NC} Script de backup não encontrado em /opt/minecraft-server/"
    echo "Copie o backup-cron.sh para /opt/minecraft-server/ primeiro"
    exit 1
fi

# Tornar executável
chmod +x /opt/minecraft-server/backup-cron.sh

echo -e "${CYAN}Escolha a frequência de backup:${NC}"
echo ""
echo "1) Diário às 3h da manhã (recomendado)"
echo "2) Duas vezes ao dia (3h e 15h)"
echo "3) A cada 4 horas"
echo "4) Semanal (domingo às 3h)"
echo "5) Personalizado"
echo ""
read -r -p "Opção (1-5): " choice

case $choice in
    1)
        CRON_LINE="0 3 * * * /opt/minecraft-server/backup-cron.sh >> /var/log/minecraft-backup.log 2>&1"
        DESC="Backup diário às 3h da manhã"
        ;;
    2)
        CRON_LINE="0 3,15 * * * /opt/minecraft-server/backup-cron.sh >> /var/log/minecraft-backup.log 2>&1"
        DESC="Backup duas vezes ao dia (3h e 15h)"
        ;;
    3)
        CRON_LINE="0 */4 * * * /opt/minecraft-server/backup-cron.sh >> /var/log/minecraft-backup.log 2>&1"
        DESC="Backup a cada 4 horas"
        ;;
    4)
        CRON_LINE="0 3 * * 0 /opt/minecraft-server/backup-cron.sh >> /var/log/minecraft-backup.log 2>&1"
        DESC="Backup semanal (domingo às 3h)"
        ;;
    5)
        echo ""
        echo "Digite a expressão cron personalizada:"
        echo "Formato: minuto hora dia-mês mês dia-semana"
        echo "Exemplos:"
        echo "  0 3 * * *    = 3h da manhã todos os dias"
        echo "  0 */6 * * *  = A cada 6 horas"
        echo "  0 2 * * 1    = 2h da manhã às segundas"
        echo ""
        read -r -p "Cron: " custom_cron
        CRON_LINE="$custom_cron /opt/minecraft-server/backup-cron.sh >> /var/log/minecraft-backup.log 2>&1"
        DESC="Backup personalizado: $custom_cron"
        ;;
    *)
        echo "Opção inválida!"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Configuração selecionada:${NC} $DESC"
echo ""

# Criar diretório de logs se não existir
sudo mkdir -p /var/log

# Adicionar ao crontab
echo "Adicionando ao crontab do root..."
(sudo crontab -l 2>/dev/null; echo ""; echo "# Minecraft Server Backup"; echo "$CRON_LINE") | sudo crontab -

echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}  Backup automático configurado!${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo "Configuração:"
echo "  $DESC"
echo ""
echo "Logs serão salvos em: /var/log/minecraft-backup.log"
echo "Backups serão salvos em: /opt/minecraft-server/backups/"
echo "Retenção: 7 dias (backups antigos são removidos automaticamente)"
echo ""
echo "Para verificar o cron:"
echo "  sudo crontab -l"
echo ""
echo "Para remover o backup automático:"
echo "  sudo crontab -e"
echo "  (remova a linha do minecraft backup)"
echo ""
echo "Para fazer backup manual:"
echo "  /opt/minecraft-server/mc-manager.sh backup"
echo "  ou"
echo "  mcbackup (se carregou os atalhos)"
echo ""

# Testar backup
read -r -p "Deseja executar um backup de teste agora? (s/N): " -n 1
echo
if [[ $REPLY =~ ^[Ss]$ ]]; then
    echo ""
    echo "Executando backup de teste..."
    sudo /opt/minecraft-server/backup-cron.sh
fi
