#!/bin/bash
# shared/lib/common.sh
#
# Shared utilities: logging, dry-run, prompts, safe IO, systemd helpers.
# This file is sourced (not executed); callers set their own error policy.

# ANSI color constants.
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
# Logging. Managers may override these for custom formats.
# ---------------------------------------------------------------------------
log() {
    # Info message with optional CRIAS_LOG_PREFIX.
    printf '%s[INFO]%s %s\n' "${BLUE}" "${NC}" "$*"
}

warn() {
    printf '%s[AVISO]%s %s\n' "${YELLOW}" "${NC}" "$*"
}

err() {
    printf '%s[ERRO]%s %s\n' "${RED}" "${NC}" "$*" >&2
}

# ISO-8601 timestamped variants (used by cron/backup scripts).
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
# Banner and step helpers.
# ---------------------------------------------------------------------------
print_header() {
    # Display repo banner if available; fallback to default.
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
# Boolean parsing and dry-run.
# ---------------------------------------------------------------------------
is_true() {
    local value="${1:-}"
    local __trim
    __trim="${value%%[![:space:]]*}"
    value="${value#"$__trim"}"
    __trim="${value##*[![:space:]]}"
    value="${value%"$__trim"}"
    # Truthy values: 1, true, yes, y, sim, s, on, enabled.
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
# Read config value from simple .env files.
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
# Run helpers with DRY_RUN support.
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
# Interactive prompts.
# ---------------------------------------------------------------------------
# Highlight a question with a separator line and color.
print_prompt() {
    local prompt="$1"
    # Separator line.
    printf '%s──────────────────────────────────────────────────────────%s\n' "${CYAN}" "${NC}"
    # Question in cyan + bold.
    printf '%s❯ %s%s\n' "${CYAN}" "$prompt" "${NC}"
}

# Yes/no prompt. Returns 0 (yes) or 1 (no).
ask_confirm() {
    local prompt="$1"
    local default_ans="${2:-Y}"
    local answer
    local prompt_text

    # Highlight the question.
    print_prompt "$prompt"

    if [ "${default_ans^^}" = "Y" ]; then
        prompt_text="${CYAN}  ➜ [Y/n]: ${NC}"
    else
        prompt_text="${CYAN}  ➜ [y/N]: ${NC}"
    fi

    # Capture SIGINT/EOF via read exit code (130 = SIGINT, 1 = EOF).
    if ! read -r -p "$(printf '%b' "$prompt_text")" answer; then
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

# Prompt for a value with default. Uses printf -v to assign to a named variable.
ask_value() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local answer

    # Highlight the question.
    print_prompt "$prompt"

    read -r -p "$(printf '%b' "${CYAN}  ➜ [${default_value}]: ${NC}")" answer
    if [ -z "$answer" ]; then
        printf -v "$var_name" '%s' "$default_value"
    else
        printf -v "$var_name" '%s' "$answer"
    fi
}

# ---------------------------------------------------------------------------
# Environment checks.
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
# Safe IO.
# ---------------------------------------------------------------------------
safe_mkdir() {
    mkdir -p "$1"
}

safe_remove_dir() {
    local target_dir="${1:-}"

    # Validate path before rm -rf.
    if ! validate_server_dir "$target_dir"; then
        print_warning "safe_remove_dir recebeu caminho invalido: '$target_dir'"
        return 1
    fi

    if [ ! -e "$target_dir" ]; then
        return 0
    fi

    rm -rf -- "$target_dir"
}

# ---------------------------------------------------------------------------
# Validate server directory before destructive ops (chown -R, rm -rf).
# Rejects empty, relative, root, and system-critical paths.
# Resolves symlinks before validation to prevent bypass.
# ---------------------------------------------------------------------------
validate_server_dir() {
    local dir="${1:-}"

    # Reject empty, root, or relative paths.
    if [ -z "$dir" ] || [ "$dir" = "/" ]; then
        print_error "Diretório de servidor inválido (vazio ou raiz): '$dir'"
        return 1
    fi

    # Must be absolute.
    if [[ "$dir" != /* ]]; then
        print_error "Diretório de servidor inválido (caminho relativo): '$dir'"
        return 1
    fi

    # Resolve symlinks (realpath -m works on non-existent paths).
    local resolved
    resolved="$(realpath -m "$dir" 2>/dev/null || echo "$dir")"

    # Reject if resolved to empty or root.
    if [ -z "$resolved" ] || [ "$resolved" = "/" ]; then
        print_error "Diretório de servidor inválido após resolução (vazio ou raiz): '$dir' -> '$resolved'"
        return 1
    fi

    # Reject system-critical areas (checked on resolved path to prevent
    # symlink bypass).
    case "$resolved" in
        /usr|/usr/*|/etc|/etc/*|/bin|/bin/*|/sbin|/sbin/*|/boot|/boot/*|\
        /root|/root/*|/lib|/lib*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|\
        /var/lib|/var/lib/*|/var/log|/var/log/*|/opt/crias-agent|/opt/crias-agent/*)
            print_error "Diretório de servidor perigoso (área do sistema): '$dir' (resolved: '$resolved')"
            return 1
            ;;
    esac

    return 0
}

sanitize_service_name() {
    # Sanitize for systemd unit file names.
    local value="${1:-}"
    echo "$value" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

# ---------------------------------------------------------------------------
# systemd helpers.
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
# Internet connectivity check. Returns 0 if reached github.com (https).
# Single source of truth — reused by mc-manifests.sh, tmodloader.sh, terraria.
# ---------------------------------------------------------------------------
has_internet() {
    command_exists curl || return 1
    curl -fsSL --connect-timeout 5 --max-time 10 https://github.com >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Virtualization detection. Returns 0 if container/VPS (skip host tuning).
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

    # Fallback: detect containers via /proc/1/cgroup.
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
# Random token generation.
# ---------------------------------------------------------------------------
generate_token() {
    local bytes="${1:-32}"
    if command_exists openssl; then
        openssl rand -hex "$bytes" 2>/dev/null
    else
        # Fallback: read from /dev/urandom.
        head -c "$bytes" /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n'
    fi
}
