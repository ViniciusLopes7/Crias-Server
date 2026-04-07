#!/bin/bash

# ============================================
# Minecraft Server Backup Script
# Para uso com cron - Backups automáticos
# ============================================

SERVER_DIR="/opt/minecraft-server"
BACKUP_DIR="$SERVER_DIR/backups"
WORLD_DIRS=("world" "world_nether" "world_the_end")
RETENTION_DAYS=7
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_NAME="minecraft-backup-$DATE.tar.zst"

# Cores (desativadas para cron)
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# YELLOW='\033[1;33m'
# NC='\033[0m'

# ============================================
# FUNÇÕES
# ============================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERRO: $1" >&2
}

check_server_running() {
    if screen -list | grep -q "minecraft"; then
        return 0
    else
        return 1
    fi
}

save_worlds() {
    log "Salvando mundos..."
    screen -S minecraft -p 0 -X stuff "save-all\n"
    sleep 5
}

pause_saves() {
    log "Pausando saves..."
    screen -S minecraft -p 0 -X stuff "save-off\n"
    sleep 2
}

resume_saves() {
    log "Retomando saves..."
    screen -S minecraft -p 0 -X stuff "save-on\n"
}

create_backup() {
    log "Criando backup: $BACKUP_NAME"
    
    mkdir -p "$BACKUP_DIR"
    cd "$SERVER_DIR" || exit 1
    
    # Criar lista de diretórios para backup (usando array para evitar word splitting)
    local backup_dirs=()
    for dir in "${WORLD_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            backup_dirs+=("$dir")
        fi
    done
    
    if [ ${#backup_dirs[@]} -eq 0 ]; then
        log_error "Nenhum diretório de mundo encontrado!"
        return 1
    fi
    
    # Criar backup com zstd e ionice idle
    if ionice -c3 tar -I 'zstd -3' -cf "$BACKUP_DIR/$BACKUP_NAME" "${backup_dirs[@]}" 2>/dev/null; then
        BACKUP_SIZE=$(du -h "$BACKUP_DIR/$BACKUP_NAME" | cut -f1)
        log "Backup criado com sucesso: $BACKUP_SIZE"
        return 0
    else
        log_error "Falha ao criar backup!"
        return 1
    fi
}

cleanup_old_backups() {
    log "Limpando backups antigos (mais de $RETENTION_DAYS dias)..."
    
    cd "$BACKUP_DIR" || return
    
    # Contar backups antes
    COUNT_BEFORE=$(find . -name "minecraft-backup-*.tar.*" -type f | wc -l)
    
    # Remover backups antigos
    find . -name "minecraft-backup-*.tar.*" -type f -mtime +"$RETENTION_DAYS" -delete
    
    # Contar backups depois
    COUNT_AFTER=$(find . -name "minecraft-backup-*.tar.*" -type f | wc -l)
    REMOVED=$((COUNT_BEFORE - COUNT_AFTER))
    
    log "Backups removidos: $REMOVED"
    log "Backups mantidos: $COUNT_AFTER"
}

notify_players() {
    local message="$1"
    if check_server_running; then
        screen -S minecraft -p 0 -X stuff "say $message\n"
    fi
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

main() {
    log "=========================================="
    log "Iniciando rotina de backup"
    log "=========================================="
    
    # Verificar se diretório do servidor existe
    if [ ! -d "$SERVER_DIR" ]; then
        log_error "Diretório do servidor não encontrado: $SERVER_DIR"
        exit 1
    fi
    
    # Verificar espaço em disco (mínimo 5GB)
    AVAILABLE_SPACE=$(df "$SERVER_DIR" | awk 'NR==2 {print $4}')
    if [ "$AVAILABLE_SPACE" -lt 5242880 ]; then  # 5GB em KB
        log_error "Espaço em disco insuficiente!"
        exit 1
    fi
    
    SERVER_WAS_RUNNING=false
    
    # Verificar se servidor está rodando
    if check_server_running; then
        SERVER_WAS_RUNNING=true
        log "Servidor está rodando"
        
        # Notificar jogadores
        notify_players "§c[Backup] §eIniciando backup automático..."
        
        # Salvar e pausar
        save_worlds
        pause_saves
    else
        log "Servidor não está rodando"
    fi
    
    # Criar backup
    if create_backup; then
        # Limpar backups antigos
        cleanup_old_backups
        
        # Notificar sucesso
        if [ "$SERVER_WAS_RUNNING" = true ]; then
            notify_players "§a[Backup] §eBackup concluído com sucesso!"
        fi
        
        log "=========================================="
        log "Backup concluído com sucesso"
        log "=========================================="
    else
        # Notificar falha
        if [ "$SERVER_WAS_RUNNING" = true ]; then
            notify_players "§c[Backup] §eFalha no backup!"
        fi
        
        log "=========================================="
        log_error "Backup falhou"
        log "=========================================="
        exit 1
    fi
    
    # Retomar saves se servidor estava rodando
    if [ "$SERVER_WAS_RUNNING" = true ]; then
        resume_saves
    fi
}

# Executar
main
