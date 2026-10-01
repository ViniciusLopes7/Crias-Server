#!/usr/bin/env bash
# shellcheck disable=SC2034

# =========================================================================
# Crias-Server ISO Profile Variables
# All variables here are consumed externally by mkarchiso; they are
# intentionally "unused" from shellcheck's perspective.
# =========================================================================

iso_name="crias-server-os"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_desc=""
git_short=""
if command -v git >/dev/null 2>&1; then
    git_desc="$(git -C "$repo_root" describe --tags --always --dirty 2>/dev/null || true)"
    git_short="$(git -C "$repo_root" rev-parse --short=6 HEAD 2>/dev/null || true)"
fi

# Keep iso_label stable and <= 11 chars (classic FAT label limit).
# Fallback para CRIAS00000 (11 chars) se git não disponível — antes era
# "CRIASNOGIT0" que poderia chocar com labels reais começando por "NOGIT".
# Sintaxe: primeiros 5 chars do git_short em UPPERCASE. Usamos duas etapas
# porque ${var::5^^} não é válido em bash (parser confunde ^^ com pattern).
if [ -n "$git_short" ]; then
    iso_label="CRIAS$(printf '%.5s' "$git_short" | tr '[:lower:]' '[:upper:]')"
else
    iso_label="CRIAS00000"
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

# Permissões explícitas para arquivos do airootfs.
# mkarchiso aplica estas permissões no momento de empacotar a ISO, sobrescrevendo
# qualquer permissão do source. Importante para garantir que o drop-in de
# autologin e o bootstrap sejam legíveis/executáveis corretamente.
#
# Formato: ["<path>"]="<uid>:<gid>:<octal_mode>"
#
# NOTA: O mkarchiso (ver archiso/mkarchiso no repo oficial) faz
# `declare -A file_permissions=()` ANTES de sourcear este arquivo. Sem isso, a
# sintaxe ["/root"]="0:0:750" falha em bash 5.2+ com "syntax error: operand
# expected". Se for sourcear este arquivo standalone (ex: em testes), faça
# `declare -A file_permissions` antes.
file_permissions=(
  ["/root"]="0:0:750"
  # Drop-in de autologin do root no tty1 (padrão archiso upstream).
  ["/etc/systemd/system/getty@tty1.service.d"]="0:0:755"
  ["/etc/systemd/system/getty@tty1.service.d/autologin.conf"]="0:0:644"
  # Bootstrap (populado por sync-airootfs.sh a partir de crias-bootstrap.sh).
  ["/usr/local/bin"]="0:0:755"
  ["/usr/local/bin/crias-bootstrap"]="0:0:755"
  ["/opt/crias-bootstrap.version"]="0:0:644"
)
