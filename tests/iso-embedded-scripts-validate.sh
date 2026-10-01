#!/bin/bash
# tests/iso-embedded-scripts-validate.sh
#
# Valida que o sync-airootfs.sh foi rodado e que os arquivos esperados estão
# presentes no airootfs: o bootstrap em /usr/local/bin/crias-bootstrap e o
# drop-in de autologin em /etc/systemd/system/getty@tty1.service.d/. Roda
# antes do mkarchiso no CI para falhar cedo se o sync foi esquecido.
#
# Este teste NÃO requer ISO construída — ele valida o filesystem do airootfs
# antes do empacotamento.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AIROOTFS="$ROOT_DIR/archiso-profile/airootfs"
BOOTSTRAP_SRC="$ROOT_DIR/crias-bootstrap.sh"
BOOTSTRAP_EMB="$AIROOTFS/usr/local/bin/crias-bootstrap"
AUTOLOGIN_DIR="$AIROOTFS/etc/systemd/system/getty@tty1.service.d"
AUTOLOGIN_FILE="$AUTOLOGIN_DIR/autologin.conf"

echo "[iso-embedded-scripts-validate] Validando airootfs em $AIROOTFS ..."

# --- 1. Diretório base do airootfs existe ---
if [ ! -d "$AIROOTFS" ]; then
    echo "FAIL: diretório $AIROOTFS não existe." >&2
    exit 1
fi

# --- 2. Bootstrap existe e bate com a fonte do repo ---
if [ ! -f "$BOOTSTRAP_EMB" ]; then
    echo "FAIL: bootstrap ausente: $BOOTSTRAP_EMB" >&2
    echo "  Rode: bash archiso-profile/sync-airootfs.sh" >&2
    exit 1
fi
if [ ! -x "$BOOTSTRAP_EMB" ]; then
    echo "FAIL: bootstrap não é executável: $BOOTSTRAP_EMB" >&2
    exit 1
fi
if [ ! -f "$BOOTSTRAP_SRC" ]; then
    echo "FAIL: fonte do bootstrap ausente no repo: $BOOTSTRAP_SRC" >&2
    exit 1
fi
if ! diff -q "$BOOTSTRAP_SRC" "$BOOTSTRAP_EMB" >/dev/null 2>&1; then
    echo "FAIL: bootstrap embutido difere da fonte do repo." >&2
    echo "  Rode sync-airootfs.sh para atualizar." >&2
    exit 1
fi
echo "  OK: bootstrap presente, executável, bate com crias-bootstrap.sh"

# --- 3. Drop-in de autologin existe e referencia --autologin root ---
if [ ! -d "$AUTOLOGIN_DIR" ]; then
    echo "FAIL: diretório de drop-in ausente: $AUTOLOGIN_DIR" >&2
    exit 1
fi
if [ ! -f "$AUTOLOGIN_FILE" ]; then
    echo "FAIL: drop-in de autologin ausente: $AUTOLOGIN_FILE" >&2
    exit 1
fi
if ! grep -Fq -- '--autologin root' "$AUTOLOGIN_FILE"; then
    echo "FAIL: drop-in não referencia '--autologin root': $AUTOLOGIN_FILE" >&2
    exit 1
fi
# Sintaxe systemd válida: deve ter [Service] e ao menos um ExecStart=.
if ! grep -Fq '[Service]' "$AUTOLOGIN_FILE"; then
    echo "FAIL: drop-in sem seção [Service]: $AUTOLOGIN_FILE" >&2
    exit 1
fi
if ! grep -Eq '^ExecStart=$' "$AUTOLOGIN_FILE"; then
    echo "FAIL: drop-in sem 'ExecStart=' (reset do default): $AUTOLOGIN_FILE" >&2
    exit 1
fi
echo "  OK: drop-in autologin presente e válido (--autologin root)"

# --- 4. Regressão: .bash_profile e .automated_script.sh NÃO devem existir ---
# (Foram removidos em F1 — o auto-start quebrado que impedia login.)
for stale in "$AIROOTFS/root/.bash_profile" "$AIROOTFS/root/.automated_script.sh" "$AIROOTFS/root/customize_airootfs.sh"; do
    if [ -e "$stale" ]; then
        echo "FAIL: arquivo stale presente (deveria ter sido removido): $stale" >&2
        exit 1
    fi
done
echo "  OK: nenhum arquivo stale de auto-start em /root/"

# --- 5. profiledef.sh declara file_permissions para os arquivos embutidos ---
profiledef="$ROOT_DIR/archiso-profile/profiledef.sh"
for path in "/usr/local/bin/crias-bootstrap" "/etc/systemd/system/getty@tty1.service.d/autologin.conf"; do
    if ! grep -Fq "[\"$path\"]" "$profiledef"; then
        echo "FAIL: profiledef.sh não declara file_permissions para $path" >&2
        exit 1
    fi
done
echo "  OK: profiledef.sh declara file_permissions para bootstrap + autologin"

# --- 6. Manifesto de versão do bootstrap ---
manifest="$AIROOTFS/opt/crias-bootstrap.version"
if [ ! -f "$manifest" ]; then
    echo "FAIL: manifesto de versão ausente: $manifest" >&2
    echo "  Rode: bash archiso-profile/sync-airootfs.sh" >&2
    exit 1
fi
for field in "synced_at" "bootstrap_sha256"; do
    if ! grep -q "^${field}=" "$manifest"; then
        echo "FAIL: manifesto ausente campo '$field'" >&2
        exit 1
    fi
done
echo "  OK: manifesto tem synced_at + bootstrap_sha256"

# --- 7. packages.x86_64 contém pacotes essenciais pro bootstrap ---
pkgs="$ROOT_DIR/archiso-profile/packages.x86_64"
for pkg in archiso base linux mkinitcpio mkinitcpio-archiso grub networkmanager tailscale openssh gum jdk21-openjdk sudo jq gettext curl unzip btop ncdu; do
    if ! grep -Eq "^${pkg}\$" "$pkgs"; then
        echo "FAIL: pacote essencial ausente em packages.x86_64: $pkg" >&2
        exit 1
    fi
done
echo "  OK: packages.x86_64 contém pacotes essenciais (incl. curl, unzip, jq pro bootstrap)"

echo "[iso-embedded-scripts-validate] OK — todos os checks passaram"
