#!/bin/bash

# Shared utility helpers used by root bootstrap and game modules.

set -u

# shellcheck disable=SC2034 # color constants exported/used by other scripts or prints
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
# shellcheck disable=SC2034 # color constant may be used by sourced scripts
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    # Try to display a repository banner if present, fallback to default header
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

is_true() {
    local value="${1:-}"
    local __trim
    __trim="${value%%[![:space:]]*}"
    value="${value#"$__trim"}"
    __trim="${value##*[![:space:]]}"
    value="${value%"$__trim"}"
    # Accepted truthy values: 1, true, yes, y, sim, s, on, enabled.
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

    trap 'echo ""; print_warning "Operacao cancelada pelo usuario (SIGINT)."; return 130' INT
    if ! read -r -p "$prompt_text" answer; then
        trap - INT
        echo ""
        print_warning "Operacao cancelada pelo usuario (EOF/SIGINT)."
        return 1
    fi
    trap - INT
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

validate_port_number() {
    local label="$1"
    local port="$2"

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        print_error "$label invalida: $port"
        print_error "Use um numero entre 1 e 65535."
        return 1
    fi

    if port_is_listening "$port"; then
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
    # Keep service names safe for systemd unit file names.
    local value="${1:-}"
    echo "$value" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}
