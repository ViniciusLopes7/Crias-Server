#!/bin/bash
# shared/lib/downloads.sh
#
# Download helper with retry/backoff and DRY_RUN support.

# Skip network in DRY_RUN.
should_skip_network() {
    if is_true "${DRY_RUN:-false}"; then
        return 0
    fi
    return 1
}

# curl with exponential backoff for 429/5xx and sane timeouts.
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

        if http_code=$(curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --retry-all-errors \
            --connect-timeout 10 \
            --max-time 300 \
            -w '%{http_code}' \
            -o "$output" \
            "$url" 2>/dev/null); then
            return 0
        fi

        case "$http_code" in
            429|500|502|503|504)
                print_warning "HTTP $http_code em tentativa $attempt (retryable)"
                ;;
            0|"")
                print_warning "Erro de rede em tentativa $attempt"
                ;;
            *)
                print_error "HTTP $http_code (nao-retryable); abortando."
                return 1
                ;;
        esac

        attempt=$((attempt + 1))
    done

    print_error "Falha apos $max_attempts tentativas: $url"
    return 1
}

# Download a file with retry. Creates parent directory if needed.
# Usage: download_file <url> <dest>
# Returns: 0=success, 1=failure
download_file() {
    local url="$1"
    local dest="$2"
    local tmpfile

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download de $url"
        return 0
    fi

    tmpfile=$(mktemp)
    # shellcheck disable=SC2064
    trap 'rm -f -- "$tmpfile"' RETURN
    mkdir -p "$(dirname "$dest")"

    if ! _curl_with_retry "$url" "$tmpfile"; then
        print_error "Falha ao baixar $url"
        rm -f "$tmpfile"
        return 1
    fi

    install -m 0644 "$tmpfile" "$dest"
    rm -f "$tmpfile"
    return 0
}

# Download a Modrinth mod with retry. Wraps API query + file download.
# Usage: download_modrinth_mod <slug> <loader> <game_version> <dest_dir> <file_name>
# Returns 0 on success, 1 on failure.
download_modrinth_mod() {
    local slug="$1"
    local loader="$2"
    local game_version="$3"
    local dest_dir="$4"
    local file_name="$5"

    if should_skip_network; then
        print_step "[DRY_RUN] Pulando download do mod $slug"
        return 0
    fi

    local api_url
    local mod_url

    api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D&game_versions=%5B%22${game_version}%22%5D"
    mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)

    if [ -z "$mod_url" ]; then
        api_url="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22${loader}%22%5D"
        mod_url=$(curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null | jq -r '.[0].files[0].url // empty' 2>/dev/null || true)
    fi

    if [ -z "$mod_url" ]; then
        print_warning "Nao foi possivel baixar o mod: $file_name"
        return 1
    fi

    mkdir -p "$dest_dir"
    if ! download_file "$mod_url" "$dest_dir/${file_name}.jar"; then
        print_warning "Falha ao baixar mod: ${file_name}, pulando."
        return 1
    fi

    print_success "Mod instalado: ${file_name}.jar"
    return 0
}
