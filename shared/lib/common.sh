#!/bin/bash
# shared/lib/common.sh
#
# Utilitários compartilhados usados pelo bootstrap raiz e pelos módulos de
# jogo (minecraft/terraria). Centraliza logging, dry-run, prompts, IO seguro
# e helpers de systemd.
#
# Este arquivo é sourced (não executado). Não coloque `set -euo pipefail`
# aqui — quem chama decide a política de erro. Apenas declara funções
# reutilizáveis.

# Cores ANSI (constants exportáveis / utilizadas via printf -v).
# shellcheck disable=SC2034
RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
# shellcheck disable=SC2034
YELLOW='\033[1;33m'
# shellcheck disable=SC2034
BLUE='\033[0;34m'
# shellcheck disable=SC2034
CYAN='\033[0;36m'
# shellcheck disable=SC2034
NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging centralizado (item 6.4 do plano).
#
# Os managers (mc-manager.sh, tt-manager.sh) e os scripts de backup costumam
# redefinir log()/warn()/err() localmente. Para evitar duplicação, fornecemos
# versões padrão aqui. Quem precisa de formato diferente (ex.: backup com
# timestamp ISO) pode sobrescrever após o source.
# ---------------------------------------------------------------------------
log() {
    # Mensagem informativa. Se o caller definir CRIAS_LOG_PREFIX, prefixa.
    printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$*"
}

warn() {
    printf '%s[AVISO]%s %s\n' "${YELLOW}" "${NC}" "$*"
}

err() {
    printf '%s[ERRO]%s %s\n' "${RED}" "${NC}" "$*" >&2
}

# Variantes prefixadas com timestamp ISO-8601 (usadas por scripts de cron/backup).
log_ts() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn_ts() {
    printf '[%s] [AVISO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

err_ts() {
    printf '[%s] [ERRO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# ---------------------------------------------------------------------------
# Helpers de banner e passos.
# ---------------------------------------------------------------------------
print_header() {
    # Tenta exibir banner do repositório se existir; fallback para default.
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local banner_paths=("$repo_root/assets/images/branding/banner.txt" "$repo_root/assets/branding/banner.txt" "/etc/crias/banner.txt")

    for p in "${banner_paths[@]}"; do
        if [ -f "$p" ]; then
            cat "$p"
            echo ""
            return 0
        fi
    done

    echo "=========================================="
    echo "  Crias-Server Installer"
    echo "  Minecraft or Terraria"
    echo "=========================================="
    echo ""
}

print_step() {
    echo -e "${BLUE}[PASSO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCESSO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

# ---------------------------------------------------------------------------
# Boolean parsing e dry-run.
# ---------------------------------------------------------------------------
is_true() {
    local value="${1:-}"
    local __trim
    __trim="${value%%[![:space:]]*}"
    value="${value#"$__trim"}"
    __trim="${value##*[![:space:]]}"
    value="${value%"$__trim"}"
    # Valores truthy aceitos: 1, true, yes, y, sim, s, on, enabled.
    case "${value,,}" in
        1|true|yes|y|sim|s|on|enabled)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

dry_run_enabled() {
    is_true "${DRY_RUN:-false}"
}

# ---------------------------------------------------------------------------
# Leitura de config (compatível com arquivos .env simples).
# ---------------------------------------------------------------------------
config_read_value() {
    local file_path="$1"
    local key="$2"
    local value

    if [ ! -f "$file_path" ]; then
        return 0
    fi

    value="$(awk -F= -v key="$key" '
        $1 == key { value = substr($0, length(key) + 2) }
        END { if (value != "") print value }
    ' "$file_path")"

    if [ -n "$value" ]; then
        printf '%s\n' "$value"
    fi
}

# ---------------------------------------------------------------------------
# Run helpers com suporte a DRY_RUN.
# ---------------------------------------------------------------------------
run_or_dry_run() {
    local description="$1"
    shift

    if dry_run_enabled; then
        print_step "[DRY_RUN] $description"
        return 0
    fi

    "$@"
}

write_file_or_dry_run() {
    local description="$1"
    local file_path="$2"

    if dry_run_enabled; then
        print_step "[DRY_RUN] $description"
        cat >/dev/null
        return 0
    fi

    cat > "$file_path"
}

# ---------------------------------------------------------------------------
# Prompts interativos.
# ---------------------------------------------------------------------------
ask_confirm() {
    local prompt="$1"
    local default_ans="${2:-Y}"
    local answer
    local prompt_text

    if [ "${default_ans^^}" = "Y" ]; then
        prompt_text="$prompt [Y/n]: "
    else
        prompt_text="$prompt [y/N]: "
    fi

    # Captura SIGINT/EOF via exit code de read (130 = SIGINT, 1 = EOF).
    # Não usar trap global aqui — seria sobrescrito por callers e vice-versa.
    if ! read -r -p "$prompt_text" answer; then
        echo ""
        print_warning "Operacao cancelada pelo usuario (EOF/SIGINT)."
        return 1
    fi

    if [ -z "$answer" ]; then
        answer="$default_ans"
    fi

    if [[ "${answer^^}" == "Y" || "${answer^^}" == "YES" || "${answer^^}" == "S" || "${answer^^}" == "SIM" ]]; then
        return 0
    fi

    return 1
}

ask_value() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local answer

    read -r -p "$prompt [$default_value]: " answer
    if [ -z "$answer" ]; then
        printf -v "$var_name" '%s' "$default_value"
    else
        printf -v "$var_name" '%s' "$answer"
    fi
}

# ---------------------------------------------------------------------------
# Verificações de ambiente.
# ---------------------------------------------------------------------------
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

port_is_listening() {
    local port="$1"

    if ! command_exists ss; then
        return 1
    fi

    ss -H -tln 2>/dev/null | awk -v port=":$port" '$4 ~ port { found=1 } END { exit found ? 0 : 1 }'
}

clamp_value() {
    local value="$1"
    local min="$2"
    local max="$3"

    if ! [[ "$value" =~ ^-?[0-9]+$ ]]; then
        echo "$min"
        return 0
    fi

    if [ "$value" -lt "$min" ]; then
        echo "$min"
        return 0
    fi

    if [ "$value" -gt "$max" ]; then
        echo "$max"
        return 0
    fi

    echo "$value"
}

validate_port_number() {
    local label="$1"
    local port="$2"
    local check_availability="${3:-false}"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "$label invalida: $port"
        print_error "Use um numero entre 1 e 65535."
        return 1
    fi

    if is_true "${check_availability:-false}" && port_is_listening "$port"; then
        print_error "Porta $port ja esta em uso."
        return 1
    fi

    return 0
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Este script precisa ser executado como root (sudo)."
        exit 1
    fi
}

check_arch() {
    if [ ! -f "/etc/arch-release" ]; then
        print_warning "Este instalador foi otimizado para Arch Linux."
        if ! ask_confirm "Deseja continuar mesmo assim?" "N"; then
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# IO seguro.
# ---------------------------------------------------------------------------
safe_mkdir() {
    mkdir -p "$1"
}

safe_remove_dir() {
    local target_dir="${1:-}"

    if [ -z "$target_dir" ] || [ "$target_dir" = "/" ]; then
        print_warning "safe_remove_dir recebeu caminho invalido: '$target_dir'"
        return 1
    fi

    if [ ! -e "$target_dir" ]; then
        return 0
    fi

    rm -rf -- "$target_dir"
}

sanitize_service_name() {
    # Mantém nomes de serviço seguros para nomes de unit files systemd.
    local value="${1:-}"
    echo "$value" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

# ---------------------------------------------------------------------------
# systemd helpers (item 6.4 do plano).
#
# systemctl_quiet_or_warn: invoca systemctl e, se falhar porque o systemd
# não está disponível (containers, ambientes de teste), apenas avisa em vez
# de abortar. Útil para scripts que precisam ser idempotentes.
# ---------------------------------------------------------------------------
systemctl_quiet_or_warn() {
    local op="$1"
    shift

    if ! command_exists systemctl; then
        warn "systemctl indisponível; pulando: systemctl $op $*"
        return 0
    fi

    systemctl "$op" "$@" >/dev/null 2>&1 || {
        local rc=$?
        warn "systemctl $op $* falhou (exit=$rc); continuando."
        return "$rc"
    }
}

# ---------------------------------------------------------------------------
# Detecção de virtualização (item S8 do plano).
#
# Retorna 0 se estiver rodando em container/VPS (skip de tuning de host),
# caso contrário retorna 1.
# ---------------------------------------------------------------------------
is_virtualized() {
    local virt=""

    if command_exists systemd-detect-virt; then
        virt="$(systemd-detect-virt 2>/dev/null || true)"
        case "$virt" in
            none|"")
                return 1
                ;;
            *)
                return 0
                ;;
        esac
    fi

    # Fallback: detectar containers via /proc/1/cgroup
    if [ -r /proc/1/cgroup ]; then
        if grep -Eq '(docker|lxc|containerd|kubepods)' /proc/1/cgroup 2>/dev/null; then
            return 0
        fi
    fi

    if [ -f /.dockerenv ]; then
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Geração de token aleatório (para o agente na Fase 1).
# ---------------------------------------------------------------------------
generate_token() {
    local bytes="${1:-32}"
    if command_exists openssl; then
        openssl rand -hex "$bytes" 2>/dev/null
    else
        # Fallback: ler de /dev/urandom
        head -c "$bytes" /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
    fi
}
