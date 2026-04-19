#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES_FILE="$ROOT_DIR/archiso-profile/packages.x86_64"
MKINITCPIO_FILE="$ROOT_DIR/archiso-profile/airootfs/etc/mkinitcpio.conf"
PROFILEDEF_FILE="$ROOT_DIR/archiso-profile/profiledef.sh"
GRUB_CFG="$ROOT_DIR/archiso-profile/grub/grub.cfg"
SYSLINUX_CFG="$ROOT_DIR/archiso-profile/syslinux/syslinux.cfg"

required_packages=(
    archiso
    base
    linux
    linux-firmware
    mkinitcpio
    syslinux
    grub
    efibootmgr
    dosfstools
    e2fsprogs
    squashfs-tools
    arch-install-scripts
)

echo "[archiso-profile-validate] Validando arquivo de pacotes..."
if [ ! -f "$PACKAGES_FILE" ]; then
    echo "Arquivo nao encontrado: $PACKAGES_FILE" >&2
    exit 1
fi

for pkg in "${required_packages[@]}"; do
    if ! grep -Fxq "$pkg" "$PACKAGES_FILE"; then
        echo "Pacote essencial ausente em packages.x86_64: $pkg" >&2
        exit 1
    fi
done

echo "[archiso-profile-validate] Validando mkinitcpio.conf do airootfs..."
if [ ! -f "$MKINITCPIO_FILE" ]; then
    echo "Arquivo nao encontrado: $MKINITCPIO_FILE" >&2
    exit 1
fi

hooks_line="$(grep -E '^[[:space:]]*HOOKS=' "$MKINITCPIO_FILE" | tail -n 1 || true)"
if [ -z "$hooks_line" ]; then
    echo "Linha HOOKS nao encontrada em $MKINITCPIO_FILE" >&2
    exit 1
fi

if ! echo "$hooks_line" | grep -q "archiso"; then
    echo "Hook archiso ausente em $MKINITCPIO_FILE" >&2
    exit 1
fi

echo "[archiso-profile-validate] Validando profiledef e bootloaders..."
if [ ! -f "$PROFILEDEF_FILE" ]; then
    echo "Arquivo nao encontrado: $PROFILEDEF_FILE" >&2
    exit 1
fi

if ! grep -Eq '^install_dir="?[a-zA-Z0-9._-]+"?$' "$PROFILEDEF_FILE"; then
    echo "install_dir ausente ou invalido em $PROFILEDEF_FILE" >&2
    exit 1
fi

if ! grep -q "bios.syslinux" "$PROFILEDEF_FILE"; then
    echo "bootmode bios.syslinux ausente em $PROFILEDEF_FILE" >&2
    exit 1
fi

if ! grep -q "uefi.grub" "$PROFILEDEF_FILE"; then
    echo "bootmode uefi.grub ausente em $PROFILEDEF_FILE" >&2
    exit 1
fi

if [ ! -f "$GRUB_CFG" ] || [ ! -f "$SYSLINUX_CFG" ]; then
    echo "Arquivos de bootloader ausentes no perfil archiso" >&2
    exit 1
fi

grep -Fq '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' "$GRUB_CFG"
grep -Fq 'archisobasedir=%INSTALL_DIR%' "$GRUB_CFG"
grep -Fq 'archisosearchuuid=%ARCHISO_UUID%' "$GRUB_CFG"

grep -Fq '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' "$SYSLINUX_CFG"
grep -Fq 'archisobasedir=%INSTALL_DIR%' "$SYSLINUX_CFG"
grep -Fq 'archisosearchuuid=%ARCHISO_UUID%' "$SYSLINUX_CFG"

echo "[archiso-profile-validate] OK"