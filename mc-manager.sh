#!/bin/bash

# ============================================
# Minecraft Server Manager Script
# Gerencia start, stop, restart, status, console, backup, update
# Com comandos facilitados para Chunky e QoL
# ============================================

SERVER_DIR="/opt/minecraft-server"
SERVER_USER="minecraft"
SERVER_JAR="server.jar"
SCREEN_NAME="minecraft"
# Inicialização delegada ao start-server.sh para manter as flags JVM em um único lugar

export SCREENDIR="$SERVER_DIR/.screen"

# Garante que este script sempre rode como o usuário configurado
if [ "$(id -nu)" != "$SERVER_USER" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        exec sudo -u "$SERVER_USER" SCREENDIR="$SCREENDIR" "$0" "$@"
    else
        echo -e "\033[0;31m[ERRO]\033[0m Este script deve ser acionado com permissões de administrador (sudo)."
        echo "Tente rodar: sudo $0 $*"
        exit 1
    fi
fi

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================
# FUNÇÕES
# ============================================

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_cmd() {
    echo -e "${CYAN}[CMD]${NC} $1"
}

check_server_running() {
    if screen -list | grep -q "${SCREEN_NAME}"; then
        return 0
    else
        return 1
    fi
}

start_server() {
    if check_server_running; then
        log_warning "Servidor já está rodando!"
        echo "Use: $0 console"
        return 1
    fi
    
    # Verificar se há RAM suficiente
    AVAILABLE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$AVAILABLE_RAM" -lt 2560 ]; then
        log_warning "Pouca RAM disponível ($AVAILABLE_RAM MB)"
        echo "O servidor pode ter problemas de performance."
        read -p "Deseja continuar mesmo assim? (s/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            echo "Operação cancelada."
            return 1
        fi
    fi
    
    log "Iniciando servidor Minecraft..."
    cd "$SERVER_DIR" || exit 1
    
    # Criar log de inicialização
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Iniciando servidor via start-server.sh..." >> "$SERVER_DIR/server-manager.log"
    
    screen -dmS "$SCREEN_NAME" bash -c "./start-server.sh"
    
    # Aguardar inicialização
    log "Aguardando inicialização..."
    sleep 5
    
    if check_server_running; then
        log "Servidor iniciado com sucesso!"
        echo -e "${BLUE}Screen:${NC} $SCREEN_NAME"
        echo -e "${BLUE}Acesse:${NC} $0 console"
        echo -e "${BLUE}Sair:${NC} Ctrl+A, depois D"
    else
        log_error "Falha ao iniciar servidor!"
        echo "Verifique os logs: $SERVER_DIR/logs/latest.log"
        return 1
    fi
}

stop_server() {
    if ! check_server_running; then
        log_warning "Servidor não está rodando!"
        return 1
    fi
    
    log "Parando servidor Minecraft..."
    
    # Avisar jogadores
    screen -S "$SCREEN_NAME" -p 0 -X stuff "say §c[Server] §eServidor será reiniciado em 10 segundos...\n"
    sleep 5
    screen -S "$SCREEN_NAME" -p 0 -X stuff "say §c[Server] §e5 segundos...\n"
    sleep 5
    
    # Salvar mundo
    log "Salvando mundo..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "save-all\n"
    sleep 3
    
    # Parar servidor
    log "Enviando comando de parada..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "stop\n"
    
    # Aguardar parada
    log "Aguardando parada..."
    for _ in {1..60}; do
        if ! check_server_running; then
            log "Servidor parado com sucesso!"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Servidor parado" >> "$SERVER_DIR/server-manager.log"
            return 0
        fi
        sleep 1
    done
    
    log_warning "Timeout aguardando parada. Forçando..."
    screen -S "$SCREEN_NAME" -X quit
    log "Servidor forçado a parar."
}

restart_server() {
    log "Reiniciando servidor..."
    stop_server
    sleep 3
    start_server
}

server_status() {
    echo "=========================================="
    echo "       STATUS DO SERVIDOR"
    echo "=========================================="
    
    if check_server_running; then
        echo -e "Status: ${GREEN}RODANDO${NC}"
        echo "Screen: $SCREEN_NAME"
        
        # Obter PID
        PID=$(pgrep -f "java.*$SERVER_JAR" | head -1)
        if [ -n "$PID" ]; then
            echo "PID: $PID"
            
            # Uso de RAM
            RAM_USAGE=$(ps -p "$PID" -o rss= | awk '{printf "%.1f MB", $1/1024}')
            echo "RAM em uso: $RAM_USAGE"
            
            # Uso de CPU
            CPU_USAGE=$(ps -p "$PID" -o %cpu=)
            echo "CPU: ${CPU_USAGE}%"
            
            # Tempo de execução
            UPTIME=$(ps -p "$PID" -o etime=)
            echo "Uptime: $UPTIME"
        fi
        
        # Jogadores online (se possível)
        if [ -f "$SERVER_DIR/logs/latest.log" ]; then
            ONLINE_PLAYERS=$(grep -oP '(?<=There are )\d+(?= of a max of)' "$SERVER_DIR/logs/latest.log" | tail -1)
            if [ -n "$ONLINE_PLAYERS" ]; then
                echo "Jogadores online: $ONLINE_PLAYERS"
            fi
        fi
        
        echo ""
        echo -e "${BLUE}Comandos disponíveis:${NC}"
        echo "  $0 console - Acessar console"
        echo "  $0 stop    - Parar servidor"
        echo "  $0 restart - Reiniciar servidor"
        echo "  $0 chunky  - Gerenciar Chunky (pré-geração)"
    else
        echo -e "Status: ${RED}PARADO${NC}"
        echo ""
        echo -e "${BLUE}Comandos disponíveis:${NC}"
        echo "  $0 start   - Iniciar servidor"
    fi
    
    echo "=========================================="
    
    # Informações do sistema
    echo ""
    echo "RECURSOS DO SISTEMA:"
    echo "=========================================="
    
    # RAM
    TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
    USED_RAM=$(free -m | awk '/^Mem:/{print $3}')
    FREE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    echo "RAM Total: ${TOTAL_RAM} MB"
    echo "RAM Usada: ${USED_RAM} MB"
    echo "RAM Livre: ${FREE_RAM} MB"
    
    # CPU Load
    LOAD=$(uptime | awk -F'load average:' '{print $2}')
    echo "Load Average:$LOAD"
    
    # Disco
    DISK_USAGE=$(df -h "$SERVER_DIR" | awk 'NR==2 {print $5}')
    echo "Uso de disco: $DISK_USAGE"
    echo "=========================================="
}

console() {
    if ! check_server_running; then
        log_error "Servidor não está rodando!"
        return 1
    fi
    
    log "Conectando ao console..."
    echo -e "${YELLOW}DICA:${NC} Para sair, pressione Ctrl+A, depois D"
    echo ""
    sleep 1
    screen -r "$SCREEN_NAME"
}

send_command() {
    if ! check_server_running; then
        log_error "Servidor não está rodando!"
        return 1
    fi
    
    shift  # Remove 'cmd' do início
    COMMAND="$*"
    
    if [ -z "$COMMAND" ]; then
        echo "Uso: $0 cmd <comando>"
        echo "Exemplo: $0 cmd say Olá mundo!"
        return 1
    fi
    
    screen -S "$SCREEN_NAME" -p 0 -X stuff "$COMMAND\n"
    log "Comando enviado: $COMMAND"
}

# ============================================
# COMANDOS FACILITADOS
# ============================================

chunky_menu() {
    echo ""
    echo "=========================================="
    echo "       CHUNKY - PRÉ-GERAÇÃO"
    echo "=========================================="
    
    if ! check_server_running; then
        log_error "Servidor precisa estar rodando!"
        return 1
    fi
    
    echo ""
    echo "O que deseja fazer?"
    echo ""
    echo "1) Iniciar pré-geração (padrão: 1000 blocos)"
    echo "2) Iniciar pré-geração (personalizado)"
    echo "3) Pausar pré-geração"
    echo "4) Continuar pré-geração"
    echo "5) Ver status/progresso"
    echo "6) Cancelar pré-geração"
    echo ""
    read -r -p "Opção (1-6): " chunky_choice
    
    case $chunky_choice in
        1)
            log "Iniciando pré-geração (raio: 1000 blocos)..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky start\n"
            log_cmd "chunky start"
            ;;
        2)
            read -r -p "Raio em blocos (ex: 500, 1000, 2000): " radius
            read -r -p "Centro X (padrão: 0): " center_x
            read -r -p "Centro Z (padrão: 0): " center_z
            center_x=${center_x:-0}
            center_z=${center_z:-0}
            
            log "Configurando área: centro ($center_x, $center_z), raio $radius"
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky center $center_x $center_z\n"
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky radius $radius\n"
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky start\n"
            log_cmd "chunky center $center_x $center_z"
            log_cmd "chunky radius $radius"
            log_cmd "chunky start"
            ;;
        3)
            log "Pausando pré-geração..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky pause\n"
            log_cmd "chunky pause"
            ;;
        4)
            log "Continuando pré-geração..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky continue\n"
            log_cmd "chunky continue"
            ;;
        5)
            log "Verificando status..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky status\n"
            log_cmd "chunky status"
            ;;
        6)
            log "Cancelando pré-geração..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "chunky cancel\n"
            log_cmd "chunky cancel"
            ;;
        *)
            echo "Opção inválida!"
            ;;
    esac
}

tps_check() {
    if ! check_server_running; then
        log_error "Servidor não está rodando!"
        return 1
    fi
    
    log "Verificando TPS (Ticks Por Segundo)..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "spark health\n"
    log_cmd "spark health"
    echo "Aguarde alguns segundos e verifique o console..."
}

players_list() {
    if ! check_server_running; then
        log_error "Servidor não está rodando!"
        return 1
    fi
    
    log "Listando jogadores online..."
    screen -S "$SCREEN_NAME" -p 0 -X stuff "list\n"
    log_cmd "list"
}

say_to_players() {
    if ! check_server_running; then
        log_error "Servidor não está rodando!"
        return 1
    fi
    
    shift  # Remove 'say' do início
    MESSAGE="$*"
    
    if [ -z "$MESSAGE" ]; then
        read -r -p "Mensagem para enviar: " MESSAGE
    fi
    
    if [ -n "$MESSAGE" ]; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "say §b[Server] §f$MESSAGE\n"
        log "Mensagem enviada: $MESSAGE"
    fi
}

whitelist_manage() {
    echo ""
    echo "=========================================="
    echo "       GERENCIAR WHITELIST"
    echo "=========================================="
    
    if ! check_server_running; then
        log_error "Servidor precisa estar rodando!"
        return 1
    fi
    
    echo ""
    echo "1) Ativar whitelist"
    echo "2) Desativar whitelist"
    echo "3) Adicionar jogador"
    echo "4) Remover jogador"
    echo "5) Listar jogadores na whitelist"
    echo ""
    read -r -p "Opção (1-5): " wl_choice
    
    case $wl_choice in
        1)
            log "Ativando whitelist..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist on\n"
            ;;
        2)
            log "Desativando whitelist..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist off\n"
            ;;
        3)
            read -r -p "Nome do jogador: " player
            log "Adicionando $player à whitelist..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist add $player\n"
            ;;
        4)
            read -r -p "Nome do jogador: " player
            log "Removendo $player da whitelist..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist remove $player\n"
            ;;
        5)
            log "Listando jogadores na whitelist..."
            screen -S "$SCREEN_NAME" -p 0 -X stuff "whitelist list\n"
            ;;
        *)
            echo "Opção inválida!"
            ;;
    esac
}

# ============================================
# BACKUP E UPDATE
# ============================================

backup() {
    log "Criando backup..."
    
    BACKUP_DIR="$SERVER_DIR/backups"
    BACKUP_NAME="backup-$(date +%Y%m%d-%H%M%S).tar.zst"
    
    mkdir -p "$BACKUP_DIR"
    
    # Parar servidor se estiver rodando
    SERVER_WAS_RUNNING=false
    if check_server_running; then
        SERVER_WAS_RUNNING=true
        log "Servidor está rodando. Criando backup online..."
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save-all\n"
        sleep 3
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save-off\n"
    fi
    
    # Criar backup com zstd (compressão mais leve/rápida) e prioridade I/O mínima
    cd "$SERVER_DIR" || exit 1
    ionice -c3 tar -I 'zstd -3' -cf "$BACKUP_DIR/$BACKUP_NAME" world/ world_nether/ world_the_end/ 2>/dev/null
    
    if [ -f "$BACKUP_DIR/$BACKUP_NAME" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)
        log "Backup criado: $BACKUP_NAME ($BACKUP_SIZE)"
        echo "Local: $BACKUP_DIR/$BACKUP_NAME"
    else
        log_error "Falha ao criar backup!"
    fi
    
    # Reativar saves
    if [ "$SERVER_WAS_RUNNING" = true ]; then
        screen -S "$SCREEN_NAME" -p 0 -X stuff "save-on\n"
    fi
    
    # Limpar backups antigos (manter últimos 7)
    cd "$BACKUP_DIR" || exit 1
    find . -maxdepth 1 -name 'backup-*.tar.*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | tail -n +8 | cut -d' ' -f2- | xargs -r rm --
}

update_modpack() {
    log "Atualizando modpack Adrenaline..."
    
    # Verificar se mrpack-install está instalado
    if ! command -v mrpack-install &> /dev/null; then
        if [ ! -f "$SERVER_DIR/mrpack-install" ]; then
            log_error "mrpack-install não encontrado!"
            return 1
        fi
        MRPACK_CMD="$SERVER_DIR/mrpack-install"
    else
        MRPACK_CMD="mrpack-install"
    fi
    
    # Backup antes de atualizar
    backup
    
    # Parar servidor
    stop_server
    
    # Atualizar
    cd "$SERVER_DIR" || exit 1
    $MRPACK_CMD update
    
    log "Modpack atualizado!"
    echo "Inicie o servidor com: $0 start"
}

mod_manager() {
    local action=$1
    local mod_name_or_id=$2

    if [ -z "$action" ]; then
        echo "Uso: mcmod <add|remove|list> [slug/nome]"
        echo "Exemplo: mcmod add chunky"
        return 1
    fi

    mkdir -p "$SERVER_DIR/mods"
    cd "$SERVER_DIR/mods" || return 1

    case "$action" in
        list)
            log "Mods instalados em $SERVER_DIR/mods:"
            find . -maxdepth 1 -name '*.jar' -printf '%f\n' 2>/dev/null || echo "Nenhum mod .jar encontrado."
            ;;
        add)
            if [ -z "$mod_name_or_id" ]; then
                log_error "Forneça o slug do mod no Modrinth. Ex: mcmod add chunky"
                return 1
            fi
            log "Buscando versão mais recente de '$mod_name_or_id' (Fabric 1.21.11) no Modrinth..."
            
            local api_url="https://api.modrinth.com/v2/project/$mod_name_or_id/version?loaders=%5B%22fabric%22%5D"
            local modrinth_url
            modrinth_url=$(curl -s "$api_url" | jq -r '.[0].files[0].url // empty')
            
            if [ -n "$modrinth_url" ]; then
                log "Baixando $modrinth_url ..."
                curl -fsSL -O "$modrinth_url"
                log "Mod '$mod_name_or_id' baixado com sucesso!"
            else
                log_error "Falha ao encontrar o mod '$mod_name_or_id' para Fabric 1.21.11. Verifique se o slug (nome na URL do Modrinth) está correto."
            fi
            ;;
        remove)
            if [ -z "$mod_name_or_id" ]; then
                log_error "Forneça parte do nome do mod para remover. Ex: mcmod remove chunky"
                return 1
            fi
            local target
            target=$(find . -maxdepth 1 -iname "*${mod_name_or_id}*" -printf '%f\n' | head -n 1)
            if [ -n "$target" ]; then
                rm "$target"
                log "Mod '$target' removido com sucesso!"
            else
                log_error "Mod contendo '$mod_name_or_id' não encontrado."
            fi
            ;;
        *)
            echo "Ação desconhecida. Use add, remove ou list."
            ;;
    esac
}

# ============================================
# MENU PRINCIPAL
# ============================================

case "$1" in
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    restart)
        restart_server
        ;;
    status)
        server_status
        ;;
    console)
        console
        ;;
    cmd)
        send_command "$@"
        ;;
    # Comandos facilitados
    chunky)
        chunky_menu
        ;;
    tps)
        tps_check
        ;;
    players)
        players_list
        ;;
    say)
        say_to_players "$@"
        ;;
    whitelist)
        whitelist_manage
        ;;
    backup)
        backup
        ;;
    update)
        update_modpack
        ;;
    mod)
        mod_manager "$2" "$3"
        ;;
    *)
        echo "=========================================="
        echo "   Minecraft Server Manager"
        echo "   Adrenaline + Chunky + QoL"
        echo "=========================================="
        echo ""
        echo "GERENCIAMENTO BÁSICO:"
        echo "  start      - Iniciar servidor"
        echo "  stop       - Parar servidor com aviso"
        echo "  restart    - Reiniciar servidor"
        echo "  status     - Mostrar status e recursos"
        echo "  console    - Acessar console (Ctrl+A,D para sair)"
        echo "  cmd        - Enviar comando ao servidor"
        echo ""
        echo "COMANDOS FACILITADOS:"
        echo "  chunky     - Gerenciar pré-geração de chunks"
        echo "  tps        - Ver TPS e saúde do servidor"
        echo "  players    - Listar jogadores online"
        echo "  say        - Enviar mensagem aos jogadores"
        echo "  whitelist  - Gerenciar whitelist"
        echo "  mod        - Gerenciar mods (add/remove/list)"
        echo ""
        echo "MANUTENÇÃO:"
        echo "  backup     - Criar backup dos mundos"
        echo "  update     - Atualizar modpack Adrenaline"
        echo ""
        echo "Exemplos:"
        echo "  $0 start"
        echo "  $0 mod add fabric-tailor"
        echo "  $0 chunky     # Menu interativo do Chunky"
        echo "  $0 say Olá jogadores!"
        echo "  $0 cmd gamemode creative Steve"
        echo "=========================================="
        exit 1
        ;;
esac
