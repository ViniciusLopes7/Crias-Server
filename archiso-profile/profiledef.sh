#!/usr/bin/env bash

# =========================================================================
# Server-Mine ISO Profile Variables
# =========================================================================

iso_name="minecraft-server-os"
iso_label="MC_ARCH_$(date +%Y%m)"
iso_publisher="Reino dos Crias <https://github.com/ViniciusLopes7/Server-Mine>"
iso_application="Servidor de Minecraft Autogerenciado / LiveCD"
iso_version="$(date +%Y.%m.%d)"

install_dir="arch"
buildmodes=('iso')
bootmodes=('bios.syslinux.mbr' 'bios.syslinux.eltorito'
           'uefi-ia32.grub.esp' 'uefi-x64.grub.esp'
           'uefi-ia32.grub.eltorito' 'uefi-x64.grub.eltorito')

arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M')

# Set bash to auto-load in live USB
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
)