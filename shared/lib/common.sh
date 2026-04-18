#!/bin/bash

# Shared utility helpers used by root bootstrap and game modules.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
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
    case "${1,,}" in
        1|true|yes|y|sim|s|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
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

    read -r -p "$prompt_text" answer
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

sanitize_service_name() {
    # Keep service names safe for systemd unit file names.
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}
