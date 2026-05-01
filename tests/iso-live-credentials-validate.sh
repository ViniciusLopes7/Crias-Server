#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Uso: $0 <caminho-da-iso>" >&2
    exit 1
fi

ISO_FILE="$1"

if [ ! -f "$ISO_FILE" ]; then
    echo "Arquivo ISO nao encontrado: $ISO_FILE" >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "bsdtar nao encontrado no ambiente." >&2
    exit 1
fi

if ! command -v unsquashfs >/dev/null 2>&1; then
    echo "unsquashfs nao encontrado no ambiente (pacote squashfs-tools)." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[iso-live-credentials-validate] Localizando squashfs na ISO..."
squashfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/x86_64/airootfs\.sfs$' | head -n 1 || true)"

if [ -z "$squashfs_rel" ]; then
    echo "airootfs.sfs nao encontrado na ISO." >&2
    exit 1
fi

echo "[iso-live-credentials-validate] Extraindo squashfs da ISO..."
bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$squashfs_rel"
squashfs_file="$WORK_DIR/$squashfs_rel"

if [ ! -f "$squashfs_file" ]; then
    echo "Falha ao extrair o airootfs.sfs da ISO." >&2
    exit 1
fi

echo "[iso-live-credentials-validate] Expandindo filesystem live..."
unsquashfs -no-progress -d "$WORK_DIR/rootfs" "$squashfs_file" >/dev/null

passwd_file="$WORK_DIR/rootfs/etc/passwd"
shadow_file="$WORK_DIR/rootfs/etc/shadow"
group_file="$WORK_DIR/rootfs/etc/group"

for required_file in "$passwd_file" "$shadow_file" "$group_file"; do
    if [ ! -f "$required_file" ]; then
        echo "Arquivo essencial ausente no rootfs live: $required_file" >&2
        exit 1
    fi
done

if ! grep -Eq '^Server:x:[0-9]+:[0-9]+:' "$passwd_file"; then
    echo "Usuario Server nao encontrado em /etc/passwd da ISO." >&2
    exit 1
fi

if ! awk -F: '$1=="wheel" { if ($4 ~ /(^|,)Server(,|$)/) ok=1 } END { exit ok ? 0 : 1 }' "$group_file"; then
    echo "Usuario Server nao esta no grupo wheel da ISO." >&2
    exit 1
fi

validate_password_enabled() {
    local user_name="$1"
    local user_hash

    user_hash="$(awk -F: -v user="$user_name" '$1==user { print $2 }' "$shadow_file")"

    if [ -z "$user_hash" ]; then
        echo "Usuario $user_name nao encontrado em /etc/shadow da ISO." >&2
        return 1
    fi

    case "$user_hash" in
        '!'|'*'|'!!'|'!*')
            echo "Senha de $user_name esta bloqueada na ISO." >&2
            return 1
            ;;
    esac

    return 0
}

validate_password_enabled "Server"
validate_password_enabled "root"

echo "[iso-live-credentials-validate] OK"