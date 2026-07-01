#!/bin/bash
# tests/iso-embedded-scripts-validate.sh
#
# Valida que o sync-airootfs.sh foi rodado e que os arquivos esperados estão
# presentes em archiso-profile/airootfs/opt/crias-server/. Roda antes do
# mkarchiso no CI para falhar cedo se o sync foi esquecido.
#
# Este teste NÃO requer ISO construída — ele valida o filesystem do airootfs
# antes do empacotamento.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMBEDDED_DIR="$ROOT_DIR/archiso-profile/airootfs/opt/crias-server"

echo "[iso-embedded-scripts-validate] Validando scripts embutidos em $EMBEDDED_DIR ..."

# --- 1. Diretório existe e tem conteúdo ---
if [ ! -d "$EMBEDDED_DIR" ]; then
    echo "FAIL: diretório $EMBEDDED_DIR não existe." >&2
    echo "  Rode: bash archiso-profile/sync-airootfs.sh" >&2
    exit 1
fi

file_count=$(find "$EMBEDDED_DIR" -type f | wc -l)
if [ "$file_count" -lt 5 ]; then
    echo "FAIL: $EMBEDDED_DIR tem apenas $file_count arquivos (esperado >= 5)." >&2
    echo "  Rode: bash archiso-profile/sync-airootfs.sh" >&2
    exit 1
fi
echo "  OK: $file_count arquivos embutidos"

# --- 2. Arquivos essenciais presentes ---
required_files=(
    "install.sh"
    "config.env"
    "packages.lock"
    "shared/lib/common.sh"
    "shared/lib/downloads.sh"
    "shared/lib/stack-installer.sh"
    "shared/lib/hardware-profile.sh"
    "minecraft/install.sh"
    "minecraft/mc-manager.sh"
    "minecraft/minecraft.service"
    "minecraft/backup-cron.sh"
    "minecraft/setup-cron.sh"
    "minecraft/start-server.sh"
    "terraria/install.sh"
    "terraria/tt-manager.sh"
    "terraria/terraria.service"
    "terraria/backup-cron.sh"
    "terraria/setup-cron.sh"
    "terraria/start-terraria.sh"
    ".sync-manifest"
)

for rel in "${required_files[@]}"; do
    target="$EMBEDDED_DIR/$rel"
    if [ ! -f "$target" ]; then
        echo "FAIL: arquivo essencial ausente: $rel" >&2
        exit 1
    fi
done
echo "  OK: todos os ${#required_files[@]} arquivos essenciais presentes"

# --- 3. Permissões executáveis nos .sh ---
non_exec_scripts=()
while IFS= read -r -d '' script; do
    if [ ! -x "$script" ]; then
        non_exec_scripts+=("$script")
    fi
done < <(find "$EMBEDDED_DIR" -name '*.sh' -type f -print0)

if [ ${#non_exec_scripts[@]} -gt 0 ]; then
    echo "FAIL: ${#non_exec_scripts[@]} script(s) sem permissão de execução:" >&2
    for s in "${non_exec_scripts[@]}"; do
        echo "  $s" >&2
    done
    echo "  Rode: find $EMBEDDED_DIR -name '*.sh' -exec chmod 755 {} +" >&2
    exit 1
fi
echo "  OK: todos os .sh têm permissão executável"

# --- 4. Manifesto tem campos obrigatórios ---
manifest="$EMBEDDED_DIR/.sync-manifest"
for field in "synced_at" "git_commit" "git_short"; do
    if ! grep -q "^${field}=" "$manifest"; then
        echo "FAIL: manifesto ausente campo '$field'" >&2
        exit 1
    fi
done
echo "  OK: manifesto tem campos synced_at/git_commit/git_short"

# --- 5. install.sh é o mesmo do repo (não foi editado manualmente) ---
repo_install="$ROOT_DIR/install.sh"
embedded_install="$EMBEDDED_DIR/install.sh"
if ! diff -q "$repo_install" "$embedded_install" >/dev/null 2>&1; then
    echo "FAIL: install.sh embutido difere do install.sh do repo." >&2
    echo "  Rode sync-airootfs.sh para atualizar." >&2
    exit 1
fi
echo "  OK: install.sh embutido bate com install.sh do repo"

# --- 6. profiledef.sh declara file_permissions para os arquivos embutidos ---
profiledef="$ROOT_DIR/archiso-profile/profiledef.sh"
for path in "/opt/crias-server/install.sh" "/opt/crias-server/config.env"; do
    if ! grep -Fq "[\"$path\"]" "$profiledef"; then
        echo "FAIL: profiledef.sh não declara file_permissions para $path" >&2
        exit 1
    fi
done
echo "  OK: profiledef.sh declara file_permissions para arquivos embutidos"

# --- 7. packages.x86_64 contém os pacotes essenciais (incluindo tailscale) ---
pkgs="$ROOT_DIR/archiso-profile/packages.x86_64"
for pkg in archiso base linux mkinitcpio mkinitcpio-archiso grub networkmanager tailscale jdk21-openjdk sudo jq gettext; do
    if ! grep -Eq "^${pkg}\$" "$pkgs"; then
        echo "FAIL: pacote essencial ausente em packages.x86_64: $pkg" >&2
        exit 1
    fi
done
echo "  OK: packages.x86_64 contém todos os pacotes essenciais (incl. tailscale)"

echo "[iso-embedded-scripts-validate] OK — todos os checks passaram"
