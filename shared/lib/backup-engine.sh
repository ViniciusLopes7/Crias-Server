#!/bin/bash
# shared/lib/backup-engine.sh
#
# Engine de backup unificado com zstd + flock + retenção por data.
# Substitui ~70% da duplicação entre minecraft/backup-cron.sh e
# terraria/backup-cron.sh (item A3 do plano).
#
# Como usar:
#
#   source "$ROOT_DIR/shared/lib/backup-engine.sh"
#
#   # Variáveis que o caller DEVE definir:
#   BACKUP_SERVER_DIR       # diretório do servidor
#   BACKUP_STACK_NAME       # "minecraft" | "terraria" (para nome de arquivo)
#   BACKUP_DIRS             # array de dirs relativos a BACKUP_SERVER_DIR
#   BACKUP_SERVICE_NAME     # nome do serviço systemd para checagem ativa
#
#   # Opcionais (com defaults):
#   BACKUP_RETENTION_DAYS=7
#   BACKUP_ZSTD_LEVEL=-3
#   BACKUP_DRY_RUN=false
#   BACKUP_REQUIRE_ACTIVE_SERVICE=true
#
#   # Hooks opcionais (definir antes de chamar backup_run):
#   backup_pre_hook()    { ... }   # ex.: RCON save-off + save-all
#   backup_post_hook()   { ... }   # ex.: RCON save-on
#
#   backup_run

# NOTA: não usar `set -u` em libs sourced — caller decide política de erro.

# ---------------------------------------------------------------------------
# Inicializa variáveis com defaults sane.
# ---------------------------------------------------------------------------
backup_init() {
    BACKUP_DIR="${BACKUP_DIR:-${BACKUP_SERVER_DIR:?}/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
    BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
    BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
    BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-${BACKUP_STACK_NAME:-minecraft}}"
    BACKUP_DATE="$(date +%Y%m%d-%H%M%S)"
    BACKUP_NAME="${BACKUP_STACK_NAME:?}-backup-${BACKUP_DATE}.tar.zst"
    BACKUP_LOCK_FD=200

    # Carrega runtime.env se existir (para herdar BACKUP_RETENTION_DAYS, etc.)
    local runtime_env="${BACKUP_SERVER_DIR}/runtime.env"
    if [ -f "$runtime_env" ]; then
        # shellcheck source=/dev/null
        source "$runtime_env"
    fi

    # Re-aplica defaults caso runtime.env tenha sobrescrito com valor vazio.
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"

    # Valida formatos.
    if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        BACKUP_RETENTION_DAYS=7
    fi
    if ! [[ "$BACKUP_ZSTD_LEVEL" =~ ^-?[0-9]+$ ]]; then
        BACKUP_ZSTD_LEVEL=-3
    fi
}

# ---------------------------------------------------------------------------
# Logging (compatível com formato cron existente).
# ---------------------------------------------------------------------------
backup_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ---------------------------------------------------------------------------
# Ajusta ownership do backup para combinar com o SERVER_DIR.
# ---------------------------------------------------------------------------
backup_owner_spec() {
    stat -c '%U:%G' "$BACKUP_SERVER_DIR" 2>/dev/null || true
}

adopt_backup_ownership() {
    local target_path="$1"
    local owner_spec

    if [ "$(id -u)" -ne 0 ]; then
        return 0
    fi

    owner_spec="$(backup_owner_spec)"
    if [ -n "$owner_spec" ] && [ "$owner_spec" != "root:root" ] && [ -e "$target_path" ]; then
        chown "$owner_spec" "$target_path" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Trava concorrência via flock (não-bloqueante).
# ---------------------------------------------------------------------------
acquire_lock() {
    mkdir -p "$BACKUP_DIR"
    adopt_backup_ownership "$BACKUP_DIR"
    exec 200>"$BACKUP_DIR/.backup.lock"
    adopt_backup_ownership "$BACKUP_DIR/.backup.lock"
    if ! flock -n "$BACKUP_LOCK_FD"; then
        backup_log "ERRO: Ja existe um backup em andamento. Abortando nova execucao."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Verifica se o serviço systemd está ativo (com skip em DRY_RUN).
# ---------------------------------------------------------------------------
is_service_active_or_skip() {
    if [ "$BACKUP_DRY_RUN" = "true" ]; then
        backup_log "[DRY_RUN] Pulando verificacao de status do servico"
        return 0
    fi

    if [ "$BACKUP_REQUIRE_ACTIVE_SERVICE" != "true" ]; then
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if ! systemctl show -p LoadState "$BACKUP_SERVICE_NAME.service" >/dev/null 2>&1; then
        backup_log "AVISO: Nao foi possivel verificar status de ${BACKUP_SERVICE_NAME}.service; seguindo backup."
        return 0
    fi

    if systemctl is-active --quiet "$BACKUP_SERVICE_NAME.service"; then
        return 0
    fi

    backup_log "Servidor ${BACKUP_SERVICE_NAME} offline. Backup cancelado."
    return 1
}

# ---------------------------------------------------------------------------
# Cria o backup propriamente dito.
#   1. Adquire lock
#   2. Chama backup_pre_hook (RCON save-off + save-all, etc.)
#   3. tar + zstd os dirs
#   4. Chama backup_post_hook (RCON save-on)
# ---------------------------------------------------------------------------
create_backup() {
    local backup_dirs=()
    local dir

    # Item: ${arr[@]:-} itera com string vazia se array está vazio;
    # ${arr[@]+"${arr[@]}"} expande para nada quando vazio (compat set -u).
    for dir in ${BACKUP_DIRS[@]+"${BACKUP_DIRS[@]}"}; do
        if [ -d "$BACKUP_SERVER_DIR/$dir" ]; then
            backup_dirs+=("$dir")
        fi
    done

    if [ ${#backup_dirs[@]} -eq 0 ]; then
        backup_log "ERRO: Nenhum diretorio de mundo encontrado em $BACKUP_SERVER_DIR."
        return 1
    fi

    if ! acquire_lock; then
        return 1
    fi

    cd "$BACKUP_SERVER_DIR" || return 1

    # Hook pre (RCON save-lock para Minecraft; no-op para Terraria).
    if declare -F backup_pre_hook >/dev/null 2>&1; then
        backup_pre_hook
    fi

    if [ "$BACKUP_DRY_RUN" = "true" ]; then
        backup_log "[DRY_RUN] Backup simulado para: ${backup_dirs[*]}"
        if declare -F backup_post_hook >/dev/null 2>&1; then
            backup_post_hook
        fi
        return 0
    fi

    # zstd só é necessário em execução real (não em DRY_RUN).
    if ! command -v zstd >/dev/null 2>&1; then
        backup_log "ERRO: zstd nao encontrado no PATH. Instale (pacman -S zstd) ou ajuste o PATH do cron."
        if declare -F backup_post_hook >/dev/null 2>&1; then
            backup_post_hook
        fi
        return 1
    fi

    if ionice -c2 -n7 tar -I "zstd ${BACKUP_ZSTD_LEVEL}" -cf "$BACKUP_DIR/$BACKUP_NAME" "${backup_dirs[@]}"; then
        adopt_backup_ownership "$BACKUP_DIR/$BACKUP_NAME"
        if declare -F backup_post_hook >/dev/null 2>&1; then
            backup_post_hook
        fi
        backup_log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        return 0
    fi

    if declare -F backup_post_hook >/dev/null 2>&1; then
        backup_post_hook
    fi
    backup_log "ERRO: Falha ao criar backup."
    return 1
}

# ---------------------------------------------------------------------------
# Limpa backups antigos por parsing de timestamp no nome.
# Fallback para find -mtime se o parse falhar.
# ---------------------------------------------------------------------------
cleanup_old_backups() {
    local cutoff_timestamp
    local backup_file
    local backup_name
    local backup_timestamp
    local pattern="${BACKUP_STACK_NAME:?}-backup-*.tar.zst"

    cutoff_timestamp="$(date -d "${BACKUP_RETENTION_DAYS} days ago" +%Y%m%d-%H%M%S 2>/dev/null || true)"
    if [ -z "$cutoff_timestamp" ]; then
        # Fallback: find por mtime (menos preciso mas funciona em BusyBox).
        find "$BACKUP_DIR" -name "$pattern" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
        return 0
    fi

    shopt -s nullglob
    for backup_file in "$BACKUP_DIR"/$pattern; do
        backup_name="$(basename "$backup_file")"
        backup_timestamp="${backup_name#${BACKUP_STACK_NAME}-backup-}"
        backup_timestamp="${backup_timestamp%.tar.zst}"

        if [[ "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$backup_timestamp" < "$cutoff_timestamp" ]]; then
            rm -f "$backup_file"
        fi
    done
    shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Ponto de entrada: orquestra toda a rotina de backup.
# ---------------------------------------------------------------------------
backup_run() {
    backup_init

    if [ ! -d "$BACKUP_SERVER_DIR" ]; then
        backup_log "ERRO: Diretorio do servidor nao encontrado: $BACKUP_SERVER_DIR"
        exit 1
    fi

    if ! is_service_active_or_skip; then
        exit 0
    fi

    if create_backup; then
        cleanup_old_backups
        backup_log "Backup concluido com sucesso."
    else
        exit 1
    fi
}
