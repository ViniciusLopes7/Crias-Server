#!/bin/bash

set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Uso: $0 <caminho-da-iso>" >&2
    exit 1
fi

ISO_FILE="$1"

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

WORK_DIR="$(mktemp -d)"
safe_cleanup_dir() {
    local target_dir="${1:-}"

    if [ -z "$target_dir" ] || [ "$target_dir" = "/" ]; then
        return 1
    fi

    rm -rf -- "$target_dir"
}

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
unsquashfs -no-progress -d "$WORK_DIR/rootfs" "$squashfs_file" >/dev/null

passwd_file="$WORK_DIR/rootfs/etc/passwd"
group_file="$WORK_DIR/rootfs/etc/group"
shadow_file="$WORK_DIR/rootfs/etc/shadow"
legacy_customizer="$WORK_DIR/rootfs/root/customize_airootfs.sh"
automated_script="$WORK_DIR/rootfs/root/.automated_script.sh"
bash_profile="$WORK_DIR/rootfs/root/.bash_profile"

for required_file in "$passwd_file" "$group_file" "$shadow_file"; do
    if [ ! -f "$required_file" ]; then
        echo "Arquivo essencial ausente no rootfs live: $required_file" >&2
        exit 1
    fi
done

if grep -Eq '^Server:' "$passwd_file"; then
    echo "Usuario 'Server' nao deveria existir por padrao na ISO (evitar credenciais hardcoded)." >&2
    exit 1
fi

if awk -F: '$1=="wheel" { if ($4 ~ /(^|,)Server(,|$)/) ok=1 } END { exit ok ? 0 : 1 }' "$group_file"; then
    echo "Usuario 'Server' nao deveria estar em wheel na ISO." >&2
    exit 1
fi

if [ -f "$legacy_customizer" ]; then
    echo "Script legado de customizacao presente na ISO: /root/customize_airootfs.sh (deveria ser removido)." >&2
    exit 1
fi

if [ ! -f "$automated_script" ]; then
    echo "Script de bootstrap ausente na ISO: /root/.automated_script.sh" >&2
    exit 1
fi

if [ ! -x "$automated_script" ]; then
    echo "Script de bootstrap nao esta executavel na ISO: /root/.automated_script.sh" >&2
    exit 1
fi

if [ ! -f "$bash_profile" ]; then
    echo "Autostart do live ISO ausente: /root/.bash_profile" >&2
    exit 1
fi

if ! grep -Fq '/root/.automated_script.sh' "$bash_profile"; then
    echo "Autostart do live ISO nao referencia /root/.automated_script.sh em /root/.bash_profile." >&2
    exit 1
fi

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
