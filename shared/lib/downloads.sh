#!/bin/bash
# shared/lib/downloads.sh
#
# Download helper with mandatory SHA256 verification, retry with backoff,
# and DRY_RUN support.
#
# Usage:
#   download_and_verify <url> <dest> <sha_env_var> [require_checksum]
#   - <sha_env_var>: env var name holding expected SHA256.
#   - require_checksum: "true" (default) to fail when checksum missing,
#                       "false" to allow unverified download.

# ---------------------------------------------------------------------------
# Skip network in DRY_RUN.
# ---------------------------------------------------------------------------
should_skip_network() {
    if is_true "${DRY_RUN:-false}"; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# curl with exponential backoff for 429/5xx and sane timeouts.
# ---------------------------------------------------------------------------
_curl_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts="${DOWNLOAD_MAX_ATTEMPTS:-4}"
    local base_delay="${DOWNLOAD_BASE_DELAY:-2}"
    local attempt=1
    local delay="$base_delay"
    local http_code

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            print_warning "Tentativa $attempt/$max_attempts apos ${delay}s (backoff)..."
            sleep "$delay"
            delay=$((delay * 2))
        fi

        # -f: fail on HTTP 4xx/5xx
        # -S: show errors
        # -s: silent
        # -L: follow redirects
        # --retry: retry transient errors (DNS, timeout)
        # --retry-all-errors: include HTTP 5xx in curl's internal retry
        # --connect-timeout: connection limit
        # --max-time: total limit
        if http_code=$(curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 10 \
            --max-time 300 \
            -w '%{http_code}' \
            -o "$output" \
            "$url" 2>/dev/null); then
            # Success
            return 0
        fi

        # Distinguish retryable 429/5xx from definitive 4xx.
        case "$http_code" in
            429|500|502|503|504)
                # Retryable.
                print_warning "HTTP $http_code em tentativa $attempt (retryable)"
                ;;
            0|"")
                # Network/DNS error — curl already retried internally.
                print_warning "Erro de rede em tentativa $attempt"
                ;;
            *)
                # Non-retryable 4xx.
                print_error "HTTP $http_code (nao-retryable); abortando."
                return 1
                ;;
        esac

        attempt=$((attempt + 1))
    done

    print_error "Falha apos $max_attempts tentativas: $url"
    return 1
}

# ---------------------------------------------------------------------------
# Download, verify SHA256, move to destination.
# Returns: 0=success, 1=network, 2=bad checksum, 3=missing required checksum,
#         4=malformed checksum.
# ---------------------------------------------------------------------------
download_and_verify() {
    local url="$1"
    local dest="$2"
    local sha_env_var="$3"
    local require_checksum="${4:-true}"
    local tmpfile

    # DRY_RUN prevents network requests.
    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download de $url"
        # No file created; callers in DRY_RUN must check before relying on it.
        return 0
    fi

    tmpfile=$(mktemp)
    # Cleanup temp file on exit.
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmpfile"' RETURN
    mkdir -p "$(dirname "$dest")"

    if ! _curl_with_retry "$url" "$tmpfile"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    # Checksum required by default.
    if [ -z "$sha_env_var" ] || [ -z "${!sha_env_var:-}" ]; then
        if [ "$require_checksum" = "true" ]; then
            print_error "Checksum SHA256 obrigatorio nao fornecido para $url"
            print_error "Defina ${sha_env_var:-<SHA_ENV_VAR>} (64 hex) em config.env ou exporte no ambiente."
            print_error "Para permitir download sem verificacao (NAO recomendado), passe require_checksum=false."
            rm -f "$tmpfile"
            return 3
        fi

        print_warning "Nenhum checksum SHA256 fornecido para $url; procedendo sem verificacao (NAO RECOMENDADO)"
        # Use `install` for atomic cross-device copy. `mv` between filesystems
        # falls back to copy+delete (non-atomic).
        install -m 0644 "$tmpfile" "$dest"
        rm -f "$tmpfile"
        return 0
    fi

    local expected
    expected="${!sha_env_var}"
    if ! [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]]; then
        print_error "Checksum SHA256 invalido em ${sha_env_var}: '$expected' (esperado: 64 hex)"
        rm -f "$tmpfile"
        return 4
    fi

    local actual
    actual=$(sha256sum "$tmpfile" | awk '{print $1}')
    if [ "${expected,,}" != "${actual,,}" ]; then
        print_error "Checksum SHA256 invalido para $url"
        print_error "esperado: $expected"
        print_error "obtido:   $actual"
        rm -f "$tmpfile"
        return 2
    fi

    # Use `install` for atomic cross-device copy.
    install -m 0644 "$tmpfile" "$dest"
    rm -f "$tmpfile"
    return 0
}

# ---------------------------------------------------------------------------
# Download a Modrinth mod with retry. Wraps API query + file download.
# Usage: download_modrinth_mod <slug> <loader> <game_version> <dest_dir> <file_name> [sha_env_var]
# Returns 0 on success, 1 on failure.
# ---------------------------------------------------------------------------
download_modrinth_mod() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local dest_dir="$4"
    local file_name="$5"
    local sha_env_var="${6:-}"

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download do mod $slug"
        return 0
    fi

    local api_url
    local mod_url

    # First attempt: filter by loader + game_version.
    api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D&game_versions=%5B%22${game_version}%22%5D"
    mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)

    # Fallback: without game_version filter.
    if [ -z "$mod_url" ]; then
        api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D"
        mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)
    fi

    if [ -z "$mod_url" ]; then
        print_warning "Nao foi possivel baixar o mod: $file_name"
        return 1
    fi

    mkdir -p "$dest_dir"
    if ! download_and_verify "$mod_url" "$dest_dir/${file_name}.jar" "$sha_env_var"; then
        print_warning "Falha ao baixar/validar mod: ${file_name}, pulando."
        return 1
    fi

    print_success "Mod instalado: ${file_name}.jar"
    return 0
}
