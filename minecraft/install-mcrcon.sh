#!/bin/bash
# Install a pinned full-screen mcrcon client for Minecraft administration.
# This script never changes server.properties or restarts the game.
# Upstream: https://github.com/mcrcon/mcrcon (not the classic AUR client).
set -euo pipefail

MCRCON_CLIENT_VERSION="v1.3.0"
MCRCON_CLIENT_REPO="mcrcon/mcrcon"
MCRCON_CLIENT_BIN_DIR="${MCRCON_CLIENT_BIN_DIR:-/usr/local/bin}"

install_mcrcon_client() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "[ERRO] O instalador do mcrcon exige root (sudo)." >&2
        return 1
    fi

    # A classic AUR binary supports RCON, but not the full-screen navigable TUI.
    # Leave an already-installed modern TUI alone (also supports newer releases).
    if command -v mcrcon >/dev/null 2>&1 && mcrcon --help 2>&1 | grep -q -- '--no-tui'; then
        echo "[mcrcon] Cliente interativo ja instalado; mantendo versao existente."
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo "[ERRO] Arquitetura nao suportada pelo mcrcon: $(uname -m)" >&2; return 1 ;;
    esac

    local ver_no_v="${MCRCON_CLIENT_VERSION#v}"
    local archive="mcrcon_${ver_no_v}_linux_${arch}.tar.gz"
    local base="https://github.com/${MCRCON_CLIENT_REPO}/releases/download/${MCRCON_CLIENT_VERSION}"
    local workdir sha
    workdir="$(mktemp -d /tmp/crias-mcrcon-XXXXXXXX)" || return 1
    chmod 0700 "$workdir" || { rm -rf -- "$workdir"; return 1; }

    local rc=0
    # Subshell traps cleanup on both successful and failed downloads.
    (
        set -euo pipefail
        trap 'rm -rf -- "$workdir"' EXIT
        echo "[mcrcon] Obtendo ${MCRCON_CLIENT_VERSION} para linux/${arch}..."
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 180 --retry 2 \
            --output "$workdir/$archive" "$base/$archive"
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 90 --retry 2 \
            --output "$workdir/checksums.txt" "$base/checksums.txt"
        sha="$(awk -v a="$archive" '($2==a || $2=="*"a) {print $1; exit}' "$workdir/checksums.txt")"
        [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || {
            echo "[ERRO] Checksum SHA-256 ausente/invalido no release do mcrcon." >&2
            exit 1
        }
        (cd "$workdir" && printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -)
        # Extract exactly the expected binary (never unpack arbitrary paths as root).
        tar -xzf "$workdir/$archive" -C "$workdir" -- mcrcon
        test -s "$workdir/mcrcon"
        "$workdir/mcrcon" --help >/dev/null
        install -d -m 0755 "$MCRCON_CLIENT_BIN_DIR"
        install -m 0755 "$workdir/mcrcon" "$MCRCON_CLIENT_BIN_DIR/mcrcon"
        echo "[mcrcon] Instalado com SHA-256 validado em $MCRCON_CLIENT_BIN_DIR/mcrcon."
    ) || rc=$?
    return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    install_mcrcon_client
fi
