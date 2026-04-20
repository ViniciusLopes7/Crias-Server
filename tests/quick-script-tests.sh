#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[quick-script-tests] Verificando sintaxe bash de todos os scripts..."
mapfile -t scripts < <(find . -type f -name "*.sh" -not -path "./.git/*" | sort)

if [ "${#scripts[@]}" -eq 0 ]; then
    echo "[quick-script-tests] Nenhum script .sh encontrado para validar." >&2
    exit 1
fi

for script in "${scripts[@]}"; do
    bash -n "$script"
done

echo "[quick-script-tests] Validando placeholders criticos de boot..."
grep -Fq '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' archiso-profile/grub/grub.cfg
grep -Fq 'archisobasedir=%INSTALL_DIR%' archiso-profile/grub/grub.cfg
grep -Fq 'archisosearchuuid=%ARCHISO_UUID%' archiso-profile/grub/grub.cfg

grep -Fq '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' archiso-profile/syslinux/syslinux.cfg
grep -Fq 'archisobasedir=%INSTALL_DIR%' archiso-profile/syslinux/syslinux.cfg
grep -Fq 'archisosearchuuid=%ARCHISO_UUID%' archiso-profile/syslinux/syslinux.cfg

echo "[quick-script-tests] Validando parser de logs do QEMU..."
bash tests/qemu-log-parser-test.sh

echo "[quick-script-tests] OK"
