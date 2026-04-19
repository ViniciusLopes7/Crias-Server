#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Uso: $0 <caminho-da-iso> [timeout-segundos]" >&2
    exit 1
fi

ISO_FILE="$1"
BOOT_TIMEOUT="${2:-240}"

if [ ! -f "$ISO_FILE" ]; then
    echo "Arquivo ISO nao encontrado: $ISO_FILE" >&2
    exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "qemu-system-x86_64 nao encontrado no ambiente." >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "bsdtar nao encontrado no ambiente." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILEDEF_FILE="$ROOT_DIR/archiso-profile/profiledef.sh"

if [ ! -f "$PROFILEDEF_FILE" ]; then
    echo "Arquivo nao encontrado: $PROFILEDEF_FILE" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
LOG_FILE="$WORK_DIR/qemu-boot.log"
trap 'rm -rf "$WORK_DIR"' EXIT

kernel_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/boot/x86_64/vmlinuz-linux$' | head -n 1 || true)"
initramfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/boot/x86_64/initramfs-linux\.img$' | head -n 1 || true)"

if [ -z "$kernel_rel" ] || [ -z "$initramfs_rel" ]; then
    echo "Kernel ou initramfs nao encontrados na ISO." >&2
    exit 1
fi

bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$kernel_rel" "$initramfs_rel"

KERNEL_FILE="$WORK_DIR/$kernel_rel"
INITRAMFS_FILE="$WORK_DIR/$initramfs_rel"

install_dir=""
iso_label=""
iso_label_from_iso=""

# Tenta ler label diretamente da ISO (mais fiel ao artefato).
iso_label_from_iso="$(blkid -o value -s LABEL "$ISO_FILE" 2>/dev/null || true)"

# shellcheck source=/dev/null
source "$PROFILEDEF_FILE"

if [ -n "$iso_label_from_iso" ]; then
    iso_label="$iso_label_from_iso"
fi

if [ -z "${install_dir:-}" ] || [ -z "${iso_label:-}" ]; then
    echo "Nao foi possivel obter install_dir/iso_label de profiledef.sh" >&2
    exit 1
fi

echo "[iso-qemu-boot] Boot smoke em QEMU (timeout=${BOOT_TIMEOUT}s)..."

set +e
timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
    -m 2048 \
    -cdrom "$ISO_FILE" \
    -kernel "$KERNEL_FILE" \
    -initrd "$INITRAMFS_FILE" \
    -append "archisobasedir=${install_dir} archisolabel=${iso_label} console=ttyS0,115200 console=tty0" \
    -nographic \
    -no-reboot \
    -monitor none \
    -serial stdio > "$LOG_FILE" 2>&1
qemu_status=$?
set -e

cp "$LOG_FILE" "$ROOT_DIR/qemu-boot.log" || true

if grep -Eqi 'Failed to start Switch Root|You are in emergency mode|Cannot open access to console|Kernel panic' "$LOG_FILE"; then
    echo "Falha de boot detectada no log do QEMU." >&2
    tail -n 120 "$LOG_FILE" >&2
    exit 1
fi

if ! grep -Eqi 'archiso|Welcome to Arch Linux|root@archiso' "$LOG_FILE"; then
    echo "Sem marcador de boot completo detectado no log do QEMU." >&2
    tail -n 120 "$LOG_FILE" >&2
    exit 1
fi

if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
    echo "QEMU retornou status inesperado: $qemu_status" >&2
    tail -n 120 "$LOG_FILE" >&2
    exit 1
fi

echo "[iso-qemu-boot] OK"