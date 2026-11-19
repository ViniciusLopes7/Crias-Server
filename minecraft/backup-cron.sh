#!/bin/bash
# minecraft/backup-cron.sh
#
# Minecraft backup using shared/lib/backup-engine.sh.
# Stack-specific: RCON save-lock before/after backup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SERVER_DIR="$SCRIPT_DIR"
if [ ! -d "$DEFAULT_SERVER_DIR/world" ] && [ -d "/opt/minecraft-server/world" ]; then
    DEFAULT_SERVER_DIR="/opt/minecraft-server"
fi

# Load shared libs (installed in .shared/ at runtime).
COMMON_LIB="$SCRIPT_DIR/.shared/common.sh"
BACKUP_LIB="$SCRIPT_DIR/.shared/backup-engine.sh"

if [ -f "$BACKUP_LIB" ]; then
    # (AUDIT-B N13) Sem `|| true`: falha ao carregar o common.sh deve derrubar
    # o script AGORA com mensagem clara, nao depois com "is_true: command not found".
    # shellcheck source=/dev/null
    source "$COMMON_LIB"
    # shellcheck source=/dev/null
    source "$BACKUP_LIB"
else
    # Dev fallback: source directly from repo.
    ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/common.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/shared/lib/backup-engine.sh"
fi

# ---------------------------------------------------------------------------
# Minecraft backup config. Variables read by backup_run() in backup-engine.sh.
# shellcheck disable=SC2034  # BACKUP_STACK_NAME, BACKUP_DIRS used by backup-engine.sh
# ---------------------------------------------------------------------------
BACKUP_SERVER_DIR="${SERVER_DIR:-$DEFAULT_SERVER_DIR}"
BACKUP_STACK_NAME="minecraft"
BACKUP_SERVICE_NAME="${BACKUP_SERVICE_NAME:-minecraft}"
BACKUP_DIRS=("world" "world_nether" "world_the_end")

# Inherit legacy variables (backward compat).
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_ZSTD_LEVEL="${BACKUP_ZSTD_LEVEL:--3}"
BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"
BACKUP_REQUIRE_ACTIVE_SERVICE="${BACKUP_REQUIRE_ACTIVE_SERVICE:-true}"
MCRCON_HOST="${MCRCON_HOST:-localhost}"
MCRCON_PORT="${MCRCON_PORT:-25575}"

# Estado do RCON save-lock (compartilhado entre hooks).
RCON_SAVE_LOCK_ACTIVE=false
RCON_PASSWORD=""

# ---------------------------------------------------------------------------
# Lê server.properties para config RCON.
# ---------------------------------------------------------------------------
read_server_property() {
    local key="$1"
    local props_file="$BACKUP_SERVER_DIR/server.properties"

    if [ ! -f "$props_file" ]; then
        return 1
    fi

    awk -F'=' -v key="$key" '
        $1 == key {
            value = substr($0, index($0, "=") + 1)
            print value
        }
    ' "$props_file" | tail -n 1
}

# ---------------------------------------------------------------------------
# Hook pre-backup: pausa saves via RCON (save-off + save-all).
# ---------------------------------------------------------------------------
backup_pre_hook() {
    local rcon_pass
    local rcon_enabled
    local rcon_port

    RCON_SAVE_LOCK_ACTIVE=false
    RCON_PASSWORD=""

    if ! command -v mcrcon >/dev/null 2>&1; then
        # (CR-06) BACKUP_REQUIRE_CONSISTENT=true: sem mcrcon o backup ABORTA —
        # copiar um mundo ativo sem save-off/save-all produz arquivo
        # potencialmente corrompido. Default: best-effort com aviso claro.
        if is_true "${BACKUP_REQUIRE_CONSISTENT:-false}"; then
            backup_log "ERRO: BACKUP_REQUIRE_CONSISTENT=true e mcrcon indisponivel; backup ABORTADO (CR-06)."
            return 1
        fi
        backup_log "AVISO: mcrcon nao encontrado. Backup BEST-EFFORT (sem save-off/save-all via RCON)."
        return 0
    fi

    rcon_enabled="$(read_server_property "enable-rcon" 2>/dev/null || true)"
    rcon_pass="$(read_server_property "rcon.password" 2>/dev/null || true)"
    rcon_port="$(read_server_property "rcon.port" 2>/dev/null || true)"

    if [ -z "$rcon_pass" ]; then
        if is_true "${BACKUP_REQUIRE_CONSISTENT:-false}"; then
            backup_log "ERRO: BACKUP_REQUIRE_CONSISTENT=true e RCON sem senha; backup ABORTADO (CR-06)."
            return 1
        fi
        backup_log "AVISO: RCON nao configurado em $BACKUP_SERVER_DIR/server.properties. Backup BEST-EFFORT."
        return 0
    fi

    if [ -n "$rcon_enabled" ] && [ "$rcon_enabled" != "true" ]; then
        if is_true "${BACKUP_REQUIRE_CONSISTENT:-false}"; then
            backup_log "ERRO: BACKUP_REQUIRE_CONSISTENT=true e enable-rcon!=true; backup ABORTADO (CR-06)."
            return 1
        fi
        backup_log "AVISO: RCON desabilitado em $BACKUP_SERVER_DIR/server.properties. Backup BEST-EFFORT."
        return 0
    fi

    if [[ "$rcon_port" =~ ^[0-9]+$ ]]; then
        MCRCON_PORT="$rcon_port"
    fi

    if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-off" >/dev/null 2>&1; then
        RCON_SAVE_LOCK_ACTIVE=true
        RCON_PASSWORD="$rcon_pass"
        backup_log "Saves pausados via RCON. Aguardando flush..."

        # save-all fail-closed (CR-16): sem flush confirmado o tar nao e
        # confiavel. Duas tentativas; falhou -> aborta o backup (o EXIT trap
        # do engine restaura save-on). Antes: `|| true` prosseguia com o tar
        # sem garantia de consistencia.
        local flush_ok=false
        local flush_attempt=1
        while [ "$flush_attempt" -le 2 ]; do
            if MCRCON_PASS="$rcon_pass" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-all" >/dev/null 2>&1; then
                flush_ok=true
                break
            fi
            flush_attempt=$((flush_attempt + 1))
            [ "$flush_attempt" -le 2 ] && sleep 2
        done
        if [ "$flush_ok" != "true" ]; then
            backup_log "ERRO: save-all falhou apos $((flush_attempt - 1)) tentativa(s); abortando backup (saves serao reativados)."
            return 1
        fi
        sleep 3
    else
        # (AUDIT-B N2) O proprio save-off FALHOU (servidor travado, conexao
        # recusada, senha errada): em modo strict o backup ABORTA — prosseguir
        # sem save-off e exatamente a inconsistencia que o CR-06 promete
        # bloquear; os 3 checkpoints anteriores nao cobriam este caso.
        if is_true "${BACKUP_REQUIRE_CONSISTENT:-false}"; then
            backup_log "ERRO: save-off falhou e BACKUP_REQUIRE_CONSISTENT=true; backup ABORTADO (CR-06)."
            return 1
        fi
        backup_log "AVISO: save-off falhou. Backup BEST-EFFORT (mundo ativo sem pausa de saves)."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Hook post-backup: reativa saves via RCON (save-on).
# ---------------------------------------------------------------------------
backup_post_hook() {
    if [ "${RCON_SAVE_LOCK_ACTIVE:-false}" != "true" ]; then
        return 0
    fi

    local attempt=1
    local max_attempts=3
    while [ "$attempt" -le "$max_attempts" ]; do
        if MCRCON_PASS="$RCON_PASSWORD" mcrcon -H "$MCRCON_HOST" -P "$MCRCON_PORT" "save-on" >/dev/null 2>&1; then
            backup_log "Saves reativados via RCON."
            RCON_SAVE_LOCK_ACTIVE=false
            _backup_clear_saveoff_alert
            return 0
        fi
        backup_log "AVISO: Falha ao reativar saves (tentativa $attempt/$max_attempts)."
        attempt=$((attempt + 1))
        [ "$attempt" -le "$max_attempts" ] && sleep 5
    done

    backup_log "ERRO CRITICO: Nao foi possivel reativar saves via RCON apos $max_attempts tentativas."
    backup_log "ERRO CRITICO: O servidor pode estar com save-off ativo. Verifique manualmente com 'mcrcon save-on'."

    # (CR-20) O estado do lock PERMANECE ARMADO (RCON_SAVE_LOCK_ACTIVE=true):
    # o EXIT trap do engine fara mais uma tentativa de save-on. Desarmar aqui
    # (comportamento antigo) fazia o trap considerar o lock inativo e abrir
    # mao da unica tentativa compensatoria restante.
    # Alerta persistente de alta visibilidade para o operador:
    local alert_file="$BACKUP_SERVER_DIR/.crias-saveoff-alert"
    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "motivo=save-on falhou apos $max_attempts tentativas no backup"
        echo "acao= rode: MCRCON_PASS=<senha> mcrcon -H localhost -P $MCRCON_PORT save-on"
        echo "       e remova este arquivo depois de confirmar."
    } > "$alert_file" 2>/dev/null || true
    backup_log "ERRO CRITICO: Alerta persistente gravado em $alert_file"
    return 1
}

# (CR-20) Sucesso remove o alerta persistente de save-off pendente.
_backup_clear_saveoff_alert() {
    local alert_file="$BACKUP_SERVER_DIR/.crias-saveoff-alert"
    if [ -f "$alert_file" ]; then
        rm -f "$alert_file" 2>/dev/null || true
        backup_log "Alerta de save-off pendente removido (save-on confirmado)."
    fi
}

# ---------------------------------------------------------------------------
# Escopo do backup (CR-13/CR-14): resolve o mundo efetivo via level-name do
# server.properties (mundos customizados nunca eram backupeados) e inclui
# configuracao essencial. Mods entram por padrao; desative com
# BACKUP_INCLUDE_MODS=false no runtime.env se os backups ficarem grandes.
# (CR-07) O runtime.env e carregado ANTES de montar o escopo: o
# BACKUP_INCLUDE_MODS so existia no runtime.env chegava APOS o backup_init —
# tarde demais para excluir mods/.
# ---------------------------------------------------------------------------
backup_load_runtime_env

MC_LEVEL_NAME="$(read_server_property "level-name" 2>/dev/null || true)"
MC_LEVEL_NAME="${MC_LEVEL_NAME:-world}"

# (EXP-51) level-name e Argumento do tar: um valor com traversal (../x),
# barra, ou prefixo '-' sairia do escopo do servidor ou seria lido como
# opcao. Um componente de caminho simples e o unico aceitavel.
# (AUDIT-B N1) Regex SEM aspas: em `[[ =~ ]]` porcao citada casa LITERAL
# (bash >= 3.2 sem compat31) — a versao citada rejeitava QUALQUER nome
# customizado (level-name=reino matava todo backup). Primeira classe SEM
# ponto: bloqueia "." e ".." e nome comecando por espaco (AUDIT-B N11).
if [ -n "$MC_LEVEL_NAME" ] && ! [[ "$MC_LEVEL_NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
    if [ "$MC_LEVEL_NAME" = "world" ]; then
        : # default seguro
    else
        echo "[ERRO] level-name rejeitado por conter caracteres inseguros para o tar: '$MC_LEVEL_NAME'" >&2
        echo "[ERRO] Use apenas letras, numeros, pontos, hifens e underscores, comecando por letra/numero/_ (EXP-51)." >&2
        exit 1
    fi
fi

BACKUP_DIRS=("$MC_LEVEL_NAME" "${MC_LEVEL_NAME}_nether" "${MC_LEVEL_NAME}_the_end" "server.properties" "config")
if is_true "${BACKUP_INCLUDE_MODS:-true}"; then
    BACKUP_DIRS+=("mods")
fi

# (CR-05) Mundo efetivo e OBRIGATORIO: sem ele o backup seria um falso
# sucesso (so configs). O engine falha antes do tar se ausente.
BACKUP_REQUIRED_DIRS=("$MC_LEVEL_NAME")

# Compat: função is_service_active_or_skip e backup_log() herdadas da backup-engine.

# Guard de execução direta: permite `source` em testes sem disparar backup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    backup_run
fi
