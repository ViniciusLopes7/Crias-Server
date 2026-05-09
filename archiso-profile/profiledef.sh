#!/usr/bin/env bash
# shellcheck disable=SC2034

# =========================================================================
# Crias-Server ISO Profile Variables
# All variables here are consumed externally by mkarchiso; they are
# intentionally "unused" from shellcheck's perspective.
# =========================================================================

iso_name="crias-server-os"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_desc="$(git -C "$repo_root" describe --tags --always --dirty 2>/dev/null || true)"
git_short="$(git -C "$repo_root" rev-parse --short=6 HEAD 2>/dev/null || true)"

# Keep iso_label stable and <= 11 chars (classic FAT label limit).
if [ -n "$git_short" ]; then
    iso_label="CRIAS${git_short^^}"
else
    iso_label="CRIASNOGIT0"
fi
iso_label="${iso_label:0:11}"
iso_publisher="Reino dos Crias <https://github.com/ViniciusLopes7/Crias-Server>"
iso_application="Servidor de Games Autogerenciado (Minecraft ou Terraria) / LiveCD"
if [ -n "$git_desc" ]; then
    iso_version="$git_desc"
else
    iso_version="nogit"
fi

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
