#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/tests/lib/assert.sh"

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
assert_file archiso-profile/grub/grub.cfg
assert_file archiso-profile/syslinux/syslinux.cfg
assert_grep_fixed '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' archiso-profile/grub/grub.cfg
assert_grep_fixed 'archisobasedir=%INSTALL_DIR%' archiso-profile/grub/grub.cfg
assert_grep_fixed 'archisosearchuuid=%ARCHISO_UUID%' archiso-profile/grub/grub.cfg

assert_grep_fixed '/%INSTALL_DIR%/boot/%ARCH%/vmlinuz-linux' archiso-profile/syslinux/syslinux.cfg
assert_grep_fixed 'archisobasedir=%INSTALL_DIR%' archiso-profile/syslinux/syslinux.cfg
assert_grep_fixed 'archisosearchuuid=%ARCHISO_UUID%' archiso-profile/syslinux/syslinux.cfg

echo "[quick-script-tests] Validando parser de logs do QEMU..."
bash tests/qemu-log-parser-test.sh

echo "[quick-script-tests] Validando parser seguro de config..."
bash tests/config-parser.sh

echo "[quick-script-tests] Validando backup dry-run do Minecraft..."
bash tests/backup-dry-run.sh

echo "[quick-script-tests] Validando backup dry-run do Terraria..."
bash tests/terraria-backup-dry-run.sh

echo "[quick-script-tests] Validando tuning do Minecraft..."
bash tests/minecraft-tuning-test.sh

echo "[quick-script-tests] Validando tuning do Terraria..."
bash tests/terraria-tuning-test.sh

echo "[quick-script-tests] Validando regressao de setup-cron (nao-root)..."
bash tests/setup-cron-manager-test.sh

echo "[quick-script-tests] Validando contrato de checksum por mod..."
assert_file minecraft/install.sh
assert_grep_fixed "file_name_norm=\"\${file_name//-/_}\"" minecraft/install.sh
assert_grep_fixed '/etc/default/cpupower-service.conf' shared/lib/system-tuning.sh
assert_grep_fixed "validate_port_number \"MINECRAFT_PORT\" \"\$MINECRAFT_PORT\"" minecraft/install.sh
assert_grep_fixed "validate_port_number \"TERRARIA_PORT\" \"\$TERRARIA_PORT\"" terraria/install.sh
assert_grep_fixed 'install_minecraft_logrotate_config()' minecraft/install.sh
assert_grep_fixed 'cmd_health()' minecraft/mc-manager.sh
assert_grep_fixed 'cmd_health()' terraria/tt-manager.sh
assert_grep_fixed 'BACKUP_DRY_RUN="${BACKUP_DRY_RUN:-false}"' terraria/backup-cron.sh

echo "[quick-script-tests] OK"
