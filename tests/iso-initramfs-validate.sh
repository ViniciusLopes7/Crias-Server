#!/bin/bash
# tests/iso-initramfs-validate.sh
#
# Valida que a ISO contém initramfs e squashfs essenciais.
# A validação de hooks internos do initramfs foi removida — o QEMU boot test
# (que roda antes deste teste e é obrigatório para release) valida na prática
# que o initramfs funciona. Listar hooks via bsdtar no Ubuntu CI não é confiável
# (initramfs é cpio+zstd multi-segment; bsdtar lista só o primeiro segmento).

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

echo "[iso-initramfs-validate] Validando tamanho do initramfs..."
initramfs_bytes="$(wc -c < "$initramfs_file")"
min_initramfs_bytes=$((10 * 1024 * 1024))

if [ "$initramfs_bytes" -lt "$min_initramfs_bytes" ]; then
    echo "initramfs-linux.img muito pequeno (${initramfs_bytes} bytes)." >&2
    exit 1
fi
echo "[iso-initramfs-validate] initramfs: ${initramfs_bytes} bytes"

echo "[iso-initramfs-validate] Validando tamanho do squashfs..."
squashfs_bytes="$(wc -c < "$squashfs_file")"
min_bytes=$((20 * 1024 * 1024))

if [ "$squashfs_bytes" -lt "$min_bytes" ]; then
    echo "airootfs.sfs muito pequeno (${squashfs_bytes} bytes)." >&2
    exit 1
fi
echo "[iso-initramfs-validate] airootfs.sfs: ${squashfs_bytes} bytes"

# Hook validation: removida. O QEMU boot test (obrigatório para release) valida
# que o initramfs funciona na prática — se os hooks archiso/archiso_loop_mnt
# estivessem ausentes, o boot falharia no QEMU antes de chegar neste teste.
echo "[iso-initramfs-validate] Validacao de hooks: coberta pelo QEMU boot test."

echo "[iso-initramfs-validate] OK"
