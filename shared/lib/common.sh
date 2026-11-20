#!/bin/bash
# shared/lib/common.sh
#
# Shared utilities: logging, dry-run, prompts, safe IO, systemd helpers.
# This file is sourced (not executed); callers set their own error policy.

# ANSI color constants. Devem conter o byte ESC REAL ($'...' ANSI-C quoting),
# não a sequência literal "\033": funções como log()/print_prompt() interpolam
# via printf '%s', que NÃO interpreta escapes — com a string literal o terminal
# exibe "\033[0;34m" cru em vez de colorir (bug reportado na v1.2.0).
# shellcheck disable=SC2034
RED=$'\033[0;31m'
# shellcheck disable=SC2034
GREEN=$'\033[0;32m'
# shellcheck disable=SC2034
YELLOW=$'\033[1;33m'
# shellcheck disable=SC2034
BLUE=$'\033[0;34m'
# shellcheck disable=SC2034
CYAN=$'\033[0;36m'
# shellcheck disable=SC2034
NC=$'\033[0m'

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
# Temp file/dir helpers with auto-cleanup via a single EXIT trap.
# Registry-based: each mktemp_crias_* appends the path to a per-process file
# (private mktemp registry); the EXIT trap reads it and removes all entries.
# This avoids bash's array-scoping quirks when arrays are modified inside
# sourced-library functions (the in-memory array approach didn't propagate
# reliably across `source` boundaries). File-based registry is robust.
# Idempotent across multiple sources (common.sh is sourced by many scripts).
# ---------------------------------------------------------------------------
if ! declare -F _crias_cleanup_temps >/dev/null 2>&1; then
    # Ignore an untrusted TMPDIR in privileged runs. For unprivileged
    # processes, accept only an existing absolute directory and canonicalize
    # it once: creation, validation and cleanup share the same base.
    _crias_temp_root=/tmp
    if [ "$EUID" -ne 0 ]; then
        _crias_candidate="${TMPDIR:-/tmp}"
        if [[ "$_crias_candidate" = /* && "$_crias_candidate" != *$'\n'* ]] \
            && [ -d "$_crias_candidate" ] && [ ! -L "$_crias_candidate" ]; then
            _crias_temp_root="$(cd -- "$_crias_candidate" && pwd -P)" || return 1 2>/dev/null || exit 1
        fi
        unset _crias_candidate
    fi
    CRIAS_TEMPS_FILE="$(mktemp "${_crias_temp_root%/}/crias-temps.XXXXXXXX")" || {
        printf "ERRO: nao foi possivel criar registro privado de temporarios\n" >&2
        return 1 2>/dev/null || exit 1
    }
    chmod 0600 -- "$CRIAS_TEMPS_FILE" || {
        rm -f -- "$CRIAS_TEMPS_FILE"
        printf "ERRO: nao foi possivel proteger registro de temporarios\n" >&2
        return 1 2>/dev/null || exit 1
    }

    # Only paths from trusted mktemp templates can be deleted by the EXIT
    # handler. Systemd units use the destination filesystem for atomic mv.
    _crias_temp_path_allowed() {
        local candidate="${1:-}"
        case "$candidate" in
            "${_crias_temp_root%/}"/crias.??????|/etc/systemd/system/crias-unit.??????.service) ;;
            *) return 1 ;;
        esac
        [ ! -L "$candidate" ] || return 1
    }

    _crias_register_temp() {
        local candidate="${1:-}"
        if ! _crias_temp_path_allowed "$candidate"; then
            print_warning "Temporario fora da politica: $candidate"
            return 1
        fi
        if ! printf "%s\n" "$candidate" >> "$CRIAS_TEMPS_FILE"; then
            print_error "Falha ao registrar temporario: $candidate"
            return 1
        fi
    }

    _crias_cleanup_temps() {
        local t
        # Never follow or trust a replaced registry.
        if [ ! -f "$CRIAS_TEMPS_FILE" ] || [ -L "$CRIAS_TEMPS_FILE" ]; then
            return 0
        fi
        while IFS= read -r t || [ -n "$t" ]; do
            [ -n "$t" ] || continue
            if ! _crias_temp_path_allowed "$t"; then
                print_warning "Ignorando entrada de temporario nao reconhecida: $t"
                continue
            fi
            if [ -e "$t" ]; then
                rm -rf -- "$t" || print_warning "Falha ao limpar temporario: $t"
            fi
        done < "$CRIAS_TEMPS_FILE"
        rm -f -- "$CRIAS_TEMPS_FILE" || true
    }
    trap _crias_cleanup_temps EXIT
fi

mktemp_crias_file() {
    local f
    f="$(mktemp "${_crias_temp_root%/}/crias.XXXXXX")" || return 1
    _crias_register_temp "$f" || { rm -f -- "$f"; return 1; }
    printf "%s\n" "$f"
}

mktemp_crias_dir() {
    local d
    d="$(mktemp -d "${_crias_temp_root%/}/crias.XXXXXX")" || return 1
    _crias_register_temp "$d" || { rmdir -- "$d" 2>/dev/null || true; return 1; }
    printf "%s\n" "$d"
}

# Remove only an exact registered temporary directory, never a symlink.
remove_crias_temp_dir() {
    local target="${1:-}"
    if ! _crias_temp_path_allowed "$target" || [[ "$target" != "${_crias_temp_root%/}"/crias.?????? ]]; then
        print_warning "Diretorio temporario nao reconhecido: $target"
        return 1
    fi
    if [ ! -f "$CRIAS_TEMPS_FILE" ] || [ -L "$CRIAS_TEMPS_FILE" ] \
        || ! grep -Fxq -- "$target" "$CRIAS_TEMPS_FILE"; then
        print_warning "Diretorio temporario nao registrado: $target"
        return 1
    fi
    if [ -e "$target" ] && [ ! -d "$target" ]; then
        print_warning "Temporario nao e mais diretorio: $target"
        return 1
    fi
    [ ! -e "$target" ] || rm -rf -- "$target"
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

# Like config_read_value, but strips one layer of surrounding double quotes
# (runtime.env writers emit KEY="value"). Used to preserve settings across
# rewrites of generated env files (CR-15).
env_file_read_value() {
    local value
    value="$(config_read_value "$1" "$2")"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
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
    local file_mode="${3:-}"

    if dry_run_enabled; then
        print_step "[DRY_RUN] $description"
        cat >/dev/null
        return 0
    fi

    # (CR-08 / AUDIT-B N12) Modo explicito opcional: arquivos com segredos
    # (runtime.env com webhook) eram criados com umask 022 -> 0644 legivel por
    # qualquer usuario local. Com modo informado o arquivo nasce 0600
    # (umask 077 na criacao — sem a janela de microssegundos do chmod tardio).
    if [ -n "$file_mode" ]; then
        (umask 077 && cat > "$file_path")
        chmod "$file_mode" "$file_path"
    else
        cat > "$file_path"
    fi
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
    # Internas com prefixo _av_: printf -v por nome sombreia a var-alvo do
    # caller se uma interna tiver o mesmo nome (ver convenção em tui.sh).
    local _av_prompt="$1"
    local _av_default="$2"
    local _av_var_name="$3"
    local _av_answer

    # Highlight the question.
    print_prompt "$_av_prompt"

    read -r -p "$(printf '%b' "${CYAN}  ➜ [${_av_default}]: ${NC}")" _av_answer
    if [ -z "$_av_answer" ]; then
        printf -v "$_av_var_name" '%s' "$_av_default"
    else
        printf -v "$_av_var_name" '%s' "$_av_answer"
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

    # (CR-32) Igualdade exata de porta: o regex antigo (":$port") fazia
    # substring — a porta 2556 conflitava com um listener em 25565. Extrai
    # a porta do endereco local (ultimo campo separado por ":", cobre
    # 0.0.0.0:P, *:P e [::]:P) e compara com igualdade.
    ss -H -tln 2>/dev/null | awk -v port="$port" '
        {
            n = split($4, addr, ":")
            if (addr[n] == port) { found = 1 }
        }
        END { exit found ? 0 : 1 }
    '
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
# (EXP-35) Allowlist: SO diretorios dedicados de instalacao sao aceitos.
# Raizes genericas (/home, /opt, /srv, /var, /tmp, /run, /mnt, /media) sao
# rejeitadas como alvo direto — um chown -R nelas destruiria o host.
# Politica: /opt/<folha>, /srv/<folha...>, /home/<usuario>/<subdir> (minimo
# 2 niveis abaixo de /home) e /var/opt/<folha>.
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

    # (EXP-35) Allowlist de raizes dedicadas. O case abaixo so ACEITA
    # subdiretorios — as raizes em si (/opt, /srv, /home, /tmp, /var/opt)
    # caem no else e sao rejeitadas. /mnt, /media, /run e o restante de /var
    # nao sao allowlistados de forma alguma. /home e /tmp exigem profundidade
    # minima 2: /home/<user> e o home INTEIRO do usuario e /tmp/<dir> e filho
    # direto de area world-writable — em ambos os casos apenas um subdiretorio
    # dedicado dentro deles e aceito como alvo.
    case "$resolved" in
        /opt/*|/srv/*|/var/opt/*)
            ;;
        /home/*/*|/tmp/*/*)
            ;;
        *)
            print_error "Diretório fora da política de instalação (EXP-35): '$dir' (resolved: '$resolved')"
            print_error "Use um diretório dedicado, ex.: /opt/minecraft-server, /srv/crias/minecraft ou /home/<usuario>/servidor."
            print_error "Raízes amplas (/home, /opt, /srv, /var, /tmp, /run, /mnt, /media) nunca são aceitas como alvo direto."
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

# ---------------------------------------------------------------------------
# (EXP-36) Versao minima de Java exigida por versao do Minecraft.
# MC 26.x exige Java 25 (anuncio oficial da Mojang para 26.1+); linhas
# anteriores (1.20.5–1.21.x) rodam com Java 21. Snapshots "26w14a" contam
# como 26.x. Usada pelo installer (pacote jdk) e pelo start-server.sh
# (validacao de major version antes do exec).
# ---------------------------------------------------------------------------
required_java_major() {
    local version="${1:-}"
    # Digitos iniciais: "26.3"->26, "26w14a"->26 (snapshot sem ponto),
    # "1.21.11"->1. Sem digitos -> 0 (cai no default 21).
    local major="${version%%[!0-9]*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 26 ]; then
        echo 25
    else
        echo 21
    fi
}
