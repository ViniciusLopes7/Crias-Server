#!/usr/bin/env bash
# shellcheck disable=SC2034

# =========================================================================
# Server-Mine ISO Profile Variables
# All variables here are consumed externally by mkarchiso; they are
# intentionally "unused" from shellcheck's perspective.
# =========================================================================

iso_name="minecraft-server-os"
iso_label="MC_ARCH_$(date +%Y%m)"
iso_publisher="Reino dos Crias <https://github.com/ViniciusLopes7/Server-Mine>"
iso_application="Servidor de Minecraft Autogerenciado / LiveCD"
iso_version="$(date +%Y.%m.%d)"

install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux' 'uefi.grub')

arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M')

# Set bash to auto-load in live USB
file_permissions=(
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
)