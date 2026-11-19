#!/bin/bash
# shared/lib/backup-engine.sh
#
# Unified backup engine with zstd + flock + date-based retention.
#
# Usage:
#
#   source "$ROOT_DIR/shared/lib/backup-engine.sh"
#
#   # Variables the caller MUST define:
#   BACKUP_SERVER_DIR       # server directory
#   BACKUP_STACK_NAME       # "minecraft" | "terraria" (for filename)
#   BACKUP_DIRS             # array of dirs relative to BACKUP_SERVER_DIR
#   BACKUP_SERVICE_NAME     # systemd service name for active check
#
#   # Optionals (with defaults):
#   BACKUP_RETENTION_DAYS=7
#   BACKUP_ZSTD_LEVEL=-3
#   BACKUP_DRY_RUN=false
#   BACKUP_REQUIRE_ACTIVE_SERVICE=true
#
#   # Optional hooks (define before calling backup_run):
#   backup_pre_hook()    { ... }   # e.g.: RCON save-off + save-all
#   backup_post_hook()   { ... }   # e.g.: RCON save-on
#
#   backup_run

# NOTE: do not use `set -u` in sourced libs; caller decides error policy.

# ---------------------------------------------------------------------------
# Initialize variables with sane defaults.
# ---------------------------------------------------------------------------
backup_init() {
    BACKUP_DIR="${BACKUP_DIR:-${BACKUP_SERVER_DIR:?}/backups}"
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
    BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
    BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
    BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-${BACKUP_STACK_NAME:-minecraft}}"
    # (EXP-50) Timestamp com nanossegundos + sufixo aleatorio: dois backups no
    # mesmo segundo compartilhavam o nome e o segundo tar sobrescrevia o
    # primeiro (flock nao protege execucoes SEQUENCIAIS).
    BACKUP_DATE="$(date +%Y%m%d-%H%M%S)-$(date +%N 2>/dev/null | tail -c 5 || echo $$)"
    BACKUP_NAME="${BACKUP_STACK_NAME:?}-backup-${BACKUP_DATE}.tar.zst"
    BACKUP_LOCK_FD=200

    # (CR-07) Load do runtime.env extraido em funcao propria: os scripts de
    # cron precisam ler BACKUP_INCLUDE_MODS ANTES de montar BACKUP_DIRS —
    # antes a montagem acontecia antes do backup_init carregar o runtime.env
    # e um `false` so nesse arquivo chegava tarde demais.
    backup_load_runtime_env

    # Re-apply defaults in case runtime.env overwrote with empty value.
    BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
    BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"

    # Validate formats. Reject 0 (would delete all backups).
    if ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || [ "$BACKUP_RETENTION_DAYS" -lt 1 ]; then
        backup_log "AVISO: BACKUP_RETENTION_DAYS=$BACKUP_RETENTION_DAYS invalido (deve ser >= 1). Usando default 7."
        BACKUP_RETENTION_DAYS=7
    fi
    if ! [[ "$BACKUP_ZSTD_LEVEL" =~ ^-?[0-9]+$ ]]; then
        BACKUP_ZSTD_LEVEL=-3
    fi
}

# Carrega o runtime.env do servidor (herda BACKUP_RETENTION_DAYS, INCLUDE_MODS,
# etc). Idempotente — pode ser chamado pelos scripts de cron antes do
# backup_init para construir o escopo com a configuracao correta (CR-07).
backup_load_runtime_env() {
    local runtime_env="${BACKUP_SERVER_DIR}/runtime.env"
    if [ -f "$runtime_env" ]; then
        if declare -F load_config_file >/dev/null 2>&1; then
            load_config_file "$runtime_env"
        else
            # Fallback: validate key=value only, no shell constructs.
            if grep -qE '(^|[^\\])\$|`|\$\(|\|\||&&|;|^[[:space:]]*(source|\.)[[:space:]]|^[[:space:]]*exit[[:space:]]' "$runtime_env" 2>/dev/null; then
                backup_log "ERRO: Arquivo env contém construções perigosas: $runtime_env"
                return 1
            fi
            # shellcheck source=/dev/null
            set -a
            source "$runtime_env"
            set +a
        fi
    fi
}

# ---------------------------------------------------------------------------
# Logging (compatible with existing cron format).
# ---------------------------------------------------------------------------
backup_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# ---------------------------------------------------------------------------
# Match backup ownership to SERVER_DIR.
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
# Acquire non-blocking flock for concurrency control.
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
    # (AUDIT-B N10) Sob o lock exclusivo: remove .partial orfaos de execucoes
    # mortas por SIGKILL/OOM (a limpeza normal nao roda nesses caminhos).
    local stale_partial
    for stale_partial in "$BACKUP_DIR"/."${BACKUP_STACK_NAME:?}"-backup-*.partial; do
        [ -e "$stale_partial" ] || continue
        backup_log "AVISO: removendo backup parcial orfao: $(basename "$stale_partial")"
        rm -f -- "$stale_partial"
    done
}

# ---------------------------------------------------------------------------
# Check if systemd service is active (skipped in DRY_RUN).
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
# Create the backup: acquire lock, run pre_hook, tar+zstd dirs, run post_hook.
# ---------------------------------------------------------------------------
create_backup() {
    local backup_dirs=()
    local dir

    # (EXP-51) Valida cada entrada ANTES de aceita-la: nomes de mundo vem do
    # server.properties (level-name) e podem conter traversal (../x), paths
    # absolutos ou prefixo de opcao (-checkpoint). Tar recebe `--` e as
    # entradas sao sempre relativas a BACKUP_SERVER_DIR.
    for dir in ${BACKUP_DIRS[@]+"${BACKUP_DIRS[@]}"}; do
        case "$dir" in
            # (AUDIT-B N11) "." e ".." explicitos tambem sao traversal.
            /*|.|..|../*|*/../*|*/..|.*|-*)
                backup_log "ERRO: Entrada de backup rejeitada (traversal/absoluta/opcao): $dir"
                return 1
                ;;
        esac
        # -e (nao -d): entradas podem ser arquivos (server.properties) alem
        # de diretorios — o escopo do backup inclui configuracao (CR-14).
        if [ -e "$BACKUP_SERVER_DIR/$dir" ]; then
            backup_dirs+=("$dir")
        fi
    done

    if [ ${#backup_dirs[@]} -eq 0 ]; then
        backup_log "ERRO: Nenhuma entrada de backup encontrada em $BACKUP_SERVER_DIR."
        return 1
    fi

    # (CR-05) Entradas OBRIGATORIAS (mundo efetivo): sem o mundo o tar pode
    # terminar "com sucesso" produzindo um backup sem dados de jogo —
    # server.properties/config sozinhos nao sao backup. BACKUP_REQUIRED_DIRS
    # e definido pelo script do stack (mc: level-name; tt: worlds/Worlds).
    local req
    for req in ${BACKUP_REQUIRED_DIRS[@]+"${BACKUP_REQUIRED_DIRS[@]}"}; do
        # A symlinked world would archive only the link, not the actual world.
        if [ -L "$BACKUP_SERVER_DIR/$req" ]; then
            backup_log "ERRO: Mundo obrigatorio e um link simbolico: $BACKUP_SERVER_DIR/$req"
            return 1
        fi
        if [ ! -e "$BACKUP_SERVER_DIR/$req" ]; then
            backup_log "ERRO: Entrada obrigatoria ausente: $BACKUP_SERVER_DIR/$req — backup SEM o mundo seria falso sucesso (CR-05)."
            return 1
        fi
    done

    if ! acquire_lock; then
        return 1
    fi

    cd "$BACKUP_SERVER_DIR" || return 1

    # Under the exclusive lock, choose a new name even if timestamps collide.
    local original_name="$BACKUP_NAME" suffix=0
    while [ -e "$BACKUP_DIR/$BACKUP_NAME" ] || [ -L "$BACKUP_DIR/$BACKUP_NAME" ]; do
        suffix=$((suffix + 1))
        BACKUP_NAME="${original_name%.tar.zst}-${suffix}.tar.zst"
    done

    # DRY_RUN: skip pre_hook entirely (don't pause saves on live server).
    if [ "$BACKUP_DRY_RUN" = "true" ]; then
        backup_log "[DRY_RUN] Backup simulado para: ${backup_dirs[*]}"
        return 0
    fi

    # O trap de restauracao precisa estar armado ANTES do pre-hook: se o
    # pre-hook falhar depois de um save-off bem-sucedido (ex.: save-all
    # falhando), o EXIT trap ainda restaura save-on (CR-02/CR-16).
    if declare -F backup_post_hook >/dev/null 2>&1; then
        # (AUDIT-B N9) Composicao com o trap do common.sh: so o post-hook
        # descartava a limpeza de temporarios registrados por mktemp_crias_*.
        if declare -F _crias_cleanup_temps >/dev/null 2>&1; then
            trap 'backup_post_hook; _crias_cleanup_temps' EXIT INT TERM
        else
            trap 'backup_post_hook' EXIT INT TERM
        fi
    fi

    # Pre hook (RCON save-lock para Minecraft; no-op para Terraria).
    # Falha do pre-hook aborta o backup (fail-closed): sem flush confirmado
    # o tar nao e confiavel. O trap acima garante save-on na saida.
    if declare -F backup_pre_hook >/dev/null 2>&1; then
        if ! backup_pre_hook; then
            backup_log "ERRO: pre-hook do backup falhou; abortando (saves serao reativados pelo trap)."
            return 1
        fi
    fi

    if ! command -v zstd >/dev/null 2>&1; then
        backup_log "ERRO: zstd nao encontrado no PATH. Instale (pacman -S zstd) ou ajuste o PATH do cron."
        return 1
    fi

    # (EXP-49) Grava em .partial e SO publica (mv) depois de validar: um tar
    # morto no meio (ENOSPC, processo morto) deixava um .tar.zst truncado com
    # nome final de backup — listavel/restore como se fosse valido.
    local partial_file="$BACKUP_DIR/.${BACKUP_NAME}.partial"
    if ionice -c2 -n7 tar -I "zstd ${BACKUP_ZSTD_LEVEL}" -cf "$partial_file" -- "${backup_dirs[@]}" \
        && zstd -t -q "$partial_file" \
        && tar -I zstd -tf "$partial_file" > /dev/null; then

        # (EXP-50) Publicacao sem sobrescrever: nome unico + guard de existencia.
        if [ -e "$BACKUP_DIR/$BACKUP_NAME" ]; then
            backup_log "ERRO: Destino de backup ja existe ($BACKUP_NAME); abortando sem sobrescrever."
            rm -f "$partial_file"
            return 1
        fi
        if ! mv -- "$partial_file" "$BACKUP_DIR/$BACKUP_NAME"; then
            backup_log "ERRO: Falha ao publicar o backup (mv)."
            rm -f "$partial_file"
            return 1
        fi
        adopt_backup_ownership "$BACKUP_DIR/$BACKUP_NAME"
        backup_log "Backup criado: $BACKUP_DIR/$BACKUP_NAME"
        # Reativa saves explicitamente no sucesso (CR-02): o trap so cobre
        # erro/sinal, e o caminho de sucesso limpava o trap sem chamar o
        # post-hook — deixando o servidor com save-off apos backup OK.
        # backup_post_hook e idempotente (guard RCON_SAVE_LOCK_ACTIVE), entao
        # o EXIT trap no fim do processo vira no-op apos o sucesso aqui.
        if declare -F backup_post_hook >/dev/null 2>&1; then
            if ! backup_post_hook; then
                backup_log "ERRO: backup criado, mas save-on falhou; tratando backup como FALHO (autosave pode estar off)."
                return 1
            fi
        fi
        return 0
    fi

    backup_log "ERRO: Falha ao criar backup (tar/validacao zstd)."
    rm -f "$partial_file"
    return 1
}

# ---------------------------------------------------------------------------
# Clean old backups by parsing timestamp in filename.
# Falls back to find -mtime if parse fails.
# ---------------------------------------------------------------------------
cleanup_old_backups() {
    local cutoff_timestamp
    local backup_file
    local backup_name
    local backup_timestamp
    local pattern="${BACKUP_STACK_NAME:?}-backup-*.tar.zst"

    cutoff_timestamp="$(date -d "${BACKUP_RETENTION_DAYS} days ago" +%Y%m%d-%H%M%S 2>/dev/null || true)"
    if [ -z "$cutoff_timestamp" ]; then
        # Fallback: find by mtime (less precise but works on BusyBox).
        find "$BACKUP_DIR" -name "$pattern" -type f -mtime +"$BACKUP_RETENTION_DAYS" -delete 2>/dev/null || true
        return 0
    fi

    shopt -s nullglob
    for backup_file in "$BACKUP_DIR"/$pattern; do
        backup_name="$(basename "$backup_file")"
        backup_timestamp="${backup_name#${BACKUP_STACK_NAME}-backup-}"
        backup_timestamp="${backup_timestamp%.tar.zst}"

        # (EXP-50) Aceita o formato novo (sufixo -NNNN apos o timestamp) e o
        # legado (timestamp puro). A comparacao usa so os 15 primeiros chars
        # (YYYYmmdd-HHMMSS), comuns aos dois formatos.
        backup_timestamp="${backup_timestamp:0:15}"
        if [[ "$backup_timestamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] && [[ "$backup_timestamp" < "$cutoff_timestamp" ]]; then
            rm -f "$backup_file"
        fi
    done
    shopt -u nullglob
}

# ---------------------------------------------------------------------------
# Entry point: orchestrate the full backup routine.
# ---------------------------------------------------------------------------
backup_remote_sync() {
    if [ -z "${BACKUP_REMOTE_PATH:-}" ]; then
        return 0
    fi
    local backup_file="$BACKUP_DIR/$BACKUP_NAME"
    if [ ! -f "$backup_file" ]; then
        backup_log "AVISO: Arquivo de backup nao encontrado para rsync: $backup_file"
        return 1
    fi
    backup_log "Sincronizando backup para $BACKUP_REMOTE_PATH ..."
    if rsync -az --timeout=300 "$backup_file" "$BACKUP_REMOTE_PATH" 2>/dev/null; then
        backup_log "Backup remoto sincronizado com sucesso."
        return 0
    else
        backup_log "AVISO: Falha no rsync para $BACKUP_REMOTE_PATH (backup local OK)."
        return 1
    fi
}

backup_notify_webhook() {
    local status="$1"
    if [ -z "${BACKUP_NOTIFY_WEBHOOK:-}" ]; then
        return 0
    fi
    local color="3066993"
    local message="Backup $BACKUP_STACK_NAME concluido com sucesso."
    if [ "$status" = "failure" ]; then
        color="15158332"
        message="Backup $BACKUP_STACK_NAME FALHOU. Verifique os logs."
    fi
    local json
    json=$(printf '{"embeds":[{"title":"Backup %s","description":"%s","color":%s,"timestamp":"%s"}]}' \
        "$BACKUP_STACK_NAME" "$message" "$color" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
    # (EXP-54) Timeout explicito: um endpoint lento/pendurado prendia o
    # servico de backup ate o TimeoutStartSec=3600 do systemd.
    if curl -fsSL --connect-timeout 10 --max-time 20 -X POST -H "Content-Type: application/json" -d "$json" "$BACKUP_NOTIFY_WEBHOOK" 2>/dev/null; then
        backup_log "Notificacao webhook enviada ($status)."
    else
        backup_log "AVISO: Falha ao enviar notificacao webhook."
    fi
}

backup_run() {
    backup_init

    if [ ! -d "$BACKUP_SERVER_DIR" ]; then
        backup_log "ERRO: Diretorio do servidor nao encontrado: $BACKUP_SERVER_DIR"
        backup_notify_webhook "failure"
        exit 1
    fi

    if ! is_service_active_or_skip; then
        exit 0
    fi

    if create_backup; then
        # Limpeza e best-effort por design: falha aqui nao invalida o backup.
        cleanup_old_backups || backup_log "AVISO: limpeza de backups antigos falhou."
        # (EXP-62) DRY_RUN e SIMULACAO: sem arquivo criado nao existe
        # "sucesso operacional" — notificar sucesso confundiria o operador.
        if is_true "${BACKUP_DRY_RUN:-false}"; then
            backup_log "[DRY_RUN] Backup simulado concluido; notificacoes suprimidas."
            return 0
        fi
        # Distingue "local OK, remoto falhou": notifica falha e sai com erro
        # para o cron/journal refletir a pendencia (antes: set -e matava o
        # processo sem nenhuma notificacao).
        if ! backup_remote_sync; then
            backup_notify_webhook "failure"
            backup_log "ERRO: backup local concluido, mas a sincronizacao remota falhou."
            exit 1
        fi
        backup_notify_webhook "success"
        backup_log "Backup concluido com sucesso."
    else
        if ! is_true "${BACKUP_DRY_RUN:-false}"; then
            backup_notify_webhook "failure"
        fi
        exit 1
    fi
}
