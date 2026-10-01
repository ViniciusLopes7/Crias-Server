#!/bin/bash
# tests/iso-live-credentials-validate.sh
#
# Valida credenciais e autologin da ISO construída. Roda contra uma ISO real
# (requer ISO_PATH). Verifica que:
#   - root está travado no /etc/shadow (autologin bypassa senha, mas shadow
#     permanece locked — hardening preservado)
#   - não existe usuário 'Server' (legado removido) em passwd/wheel
#   - não existe /root/customize_airootfs.sh (legado removido)
#   - não existe /root/.bash_profile nem /root/.automated_script.sh (auto-start
#     quebrado removido em F1)
#   - existe drop-in de autologin em /etc/systemd/system/getty@tty1.service.d/
#     que referencia --autologin root

set -euo pipefail

ISO_FILE="${1:-${ISO_PATH:-}}"

if [ -z "$ISO_FILE" ]; then
    echo "Uso: $0 <caminho-da-iso> (ou export ISO_PATH=<caminho>)" >&2
    exit 1
fi

if [ ! -f "$ISO_FILE" ]; then
    echo "Arquivo ISO nao encontrado: $ISO_FILE" >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "bsdtar nao encontrado no ambiente." >&2
    exit 1
fi

if ! command -v unsquashfs >/dev/null 2>&1; then
    echo "unsquashfs nao encontrado no ambiente (pacote squashfs-tools)." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
source "$ROOT_DIR/tests/lib/cleanup.sh"

trap 'safe_cleanup_dir "$WORK_DIR" || true' EXIT

echo "[iso-live-credentials-validate] Localizando squashfs na ISO..."
squashfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/x86_64/airootfs\.sfs$' | head -n 1 || true)"

if [ -z "$squashfs_rel" ]; then
    echo "airootfs.sfs nao encontrado na ISO." >&2
    exit 1
fi

echo "[iso-live-credentials-validate] Extraindo squashfs da ISO..."
bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$squashfs_rel"
squashfs_file="$WORK_DIR/$squashfs_rel"

if [ ! -f "$squashfs_file" ]; then
    echo "Falha ao extrair o airootfs.sfs da ISO." >&2
    exit 1
fi

echo "[iso-live-credentials-validate] Expandindo filesystem live..."
unsquashfs -no-progress -no-xattrs -d "$WORK_DIR/rootfs" "$squashfs_file" >/dev/null

passwd_file="$WORK_DIR/rootfs/etc/passwd"
group_file="$WORK_DIR/rootfs/etc/group"
shadow_file="$WORK_DIR/rootfs/etc/shadow"
autologin_dir="$WORK_DIR/rootfs/etc/systemd/system/getty@tty1.service.d"
autologin_file="$autologin_dir/autologin.conf"

for required_file in "$passwd_file" "$group_file" "$shadow_file"; do
    if [ ! -f "$required_file" ]; then
        echo "Arquivo essencial ausente no rootfs live: $required_file" >&2
        exit 1
    fi
done

# --- Usuário 'Server' legado não deve existir ---
if grep -Eq '^Server:' "$passwd_file"; then
    echo "Usuario 'Server' nao deveria existir por padrao na ISO (evitar credenciais hardcoded)." >&2
    exit 1
fi

if awk -F: '$1=="wheel" { if ($4 ~ /(^|,)Server(,|$)/) ok=1 } END { exit ok ? 0 : 1 }' "$group_file"; then
    echo "Usuario 'Server' nao deveria estar em wheel na ISO." >&2
    exit 1
fi

# --- Scripts legados não devem existir ---
for legacy in \
    "$WORK_DIR/rootfs/root/customize_airootfs.sh" \
    "$WORK_DIR/rootfs/root/.bash_profile" \
    "$WORK_DIR/rootfs/root/.automated_script.sh"; do
    if [ -f "$legacy" ]; then
        echo "Arquivo legacy presente na ISO (deveria ter sido removido): ${legacy#$WORK_DIR/rootfs}" >&2
        exit 1
    fi
done

# --- Drop-in de autologin do root no tty1 deve existir e ser válido ---
if [ ! -d "$autologin_dir" ]; then
    echo "Diretório de drop-in de autologin ausente: ${autologin_dir#$WORK_DIR/rootfs}" >&2
    exit 1
fi
if [ ! -f "$autologin_file" ]; then
    echo "Drop-in de autologin ausente: ${autologin_file#$WORK_DIR/rootfs}" >&2
    exit 1
fi
if ! grep -Fq -- '--autologin root' "$autologin_file"; then
    echo "Drop-in de autologin não referencia '--autologin root': ${autologin_file#$WORK_DIR/rootfs}" >&2
    exit 1
fi

# --- Root deve estar travado (autologin bypassa senha, mas shadow permanece locked) ---
root_hash="$(awk -F: '$1=="root" { print $2 }' "$shadow_file" || true)"
if [ -z "$root_hash" ]; then
    echo "Usuario root nao encontrado em /etc/shadow da ISO." >&2
    exit 1
fi

case "$root_hash" in
    '!'|'*'|'!!'|'!*'|'!*'*) ;;
    *)
        echo "Senha do root aparenta estar habilitada na ISO (esperado: bloqueada)." >&2
        exit 1
        ;;
esac

echo "[iso-live-credentials-validate] OK"
