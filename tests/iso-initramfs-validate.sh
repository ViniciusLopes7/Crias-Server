#!/bin/bash

set -euo pipefail

ISO_FILE="${1:-${ISO_PATH:-}}"

if [ -z "$ISO_FILE" ]; then
    echo "Uso: $0 <caminho-da-iso> (ou export ISO_PATH=<caminho>)" >&2
    exit 1
fi

if [ ! -f "$ISO_FILE" ]; then
    echo "Arquivo ISO nao encontrado: $ISO_FILE" >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "bsdtar nao encontrado no ambiente." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
# Helper safe_cleanup_dir sourced from tests/lib/cleanup.sh (DRY).
source "$ROOT_DIR/tests/lib/cleanup.sh"

trap 'safe_cleanup_dir "$WORK_DIR" || true' EXIT

echo "[iso-initramfs-validate] Localizando arquivos na ISO..."
initramfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/boot/x86_64/initramfs-linux\.img$' | head -n 1 || true)"
squashfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/x86_64/airootfs\.sfs$' | head -n 1 || true)"

if [ -z "$initramfs_rel" ]; then
    echo "initramfs-linux.img nao encontrado na ISO." >&2
    exit 1
fi

if [ -z "$squashfs_rel" ]; then
    echo "airootfs.sfs nao encontrado na ISO." >&2
    exit 1
fi

echo "[iso-initramfs-validate] Extraindo initramfs e squashfs..."
bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$initramfs_rel" "$squashfs_rel"

initramfs_file="$WORK_DIR/$initramfs_rel"
squashfs_file="$WORK_DIR/$squashfs_rel"

if [ ! -f "$initramfs_file" ] || [ ! -f "$squashfs_file" ]; then
    echo "Falha ao extrair arquivos essenciais da ISO." >&2
    exit 1
fi

echo "[iso-initramfs-validate] Validando hooks do initramfs..."
required_hooks=(archiso archiso_loop_mnt base udev block filesystems keyboard)
hook_listing="$WORK_DIR/initramfs-hooks.txt"
# bsdtar lists cpio contents (initramfs is a compressed cpio archive).
# This replaces the Arch-specific lsinitcpio, making the test portable.
bsdtar -tf "$initramfs_file" > "$hook_listing" 2>/dev/null

for hook in "${required_hooks[@]}"; do
    if ! grep -Eq "(^|/)hooks/${hook}$" "$hook_listing"; then
        echo "Hook obrigatorio ausente no initramfs: $hook" >&2
        exit 1
    fi
done

echo "[iso-initramfs-validate] Validando tamanho do squashfs..."
squashfs_bytes="$(wc -c < "$squashfs_file")"
min_bytes=$((20 * 1024 * 1024))

if [ "$squashfs_bytes" -lt "$min_bytes" ]; then
    echo "airootfs.sfs muito pequeno (${squashfs_bytes} bytes)." >&2
    exit 1
fi

echo "[iso-initramfs-validate] Hooks encontrados:"
grep -E '(^|/)hooks/(archiso|archiso_loop_mnt|base|udev|block|filesystems|keyboard)$' "$hook_listing" | sort -u

echo "[iso-initramfs-validate] OK"