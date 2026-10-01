#!/bin/bash
# archiso-profile/sync-airootfs.sh
#
# Sincroniza o bootstrap do Crias-Server do repo (raiz) para dentro do airootfs
# da ISO, em /usr/local/bin/crias-bootstrap. O bootstrap é pequeno (~5KB) e
# responsável por baixar a release do GitHub (com verificação SHA256) e extrair
# para o sistema alvo.
#
# Este script deve ser rodado ANTES do `mkarchiso` (no CI ou localmente).
#
# Por que só o bootstrap (e não o repo inteiro):
#   - O repo embutido em /opt/crias-server/ era inútil depois do reboot
#     (archinstall cria rootfs limpo; /opt/crias-server/ não sobrevive).
#   - O bootstrap baixa a release correta do GitHub com checksum, garantindo
#     integridade e versão rastreável.
#   - ISO fica menor (só archiso base + pacotes pré-instalados + bootstrap).
#
# Uso:
#   bash archiso-profile/sync-airootfs.sh
#
# Saída: preenche archiso-profile/airootfs/usr/local/bin/crias-bootstrap.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="$SCRIPT_DIR/airootfs/usr/local/bin"
TARGET_FILE="$TARGET_DIR/crias-bootstrap"
SOURCE_FILE="$REPO_ROOT/crias-bootstrap.sh"

echo "[sync-airootfs] Repo root: $REPO_ROOT"
echo "[sync-airootfs] Target:    $TARGET_FILE"

if [ ! -f "$SOURCE_FILE" ]; then
    echo "[sync-airootfs] ERRO: $SOURCE_FILE não existe no repo." >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"
cp -a "$SOURCE_FILE" "$TARGET_FILE"

    # Hub TUI central (menu interativo sem precisar lembrar comandos do manager).
    tui_source="$REPO_ROOT/crias-tui.sh"
    tui_target="$SCRIPT_DIR/airootfs/usr/local/bin/crias-tui"
    if [ -f "$tui_source" ]; then
        cp -a "$tui_source" "$tui_target"
        chmod 0755 "$tui_target"
        echo "[sync-airootfs]   $tui_target ($(wc -c < "$tui_target") bytes)"
    fi
chmod 0755 "$TARGET_FILE"

# Manifesto de auditoria: qual commit gerou esta ISO.
MANIFEST="$SCRIPT_DIR/airootfs/opt/crias-bootstrap.version"
mkdir -p "$(dirname "$MANIFEST")"
{
    echo "# Gerado por sync-airootfs.sh — não editar manualmente."
    echo "synced_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    if command -v git >/dev/null 2>&1; then
        echo "git_commit=\"$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)\""
        echo "git_short=\"$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)\""
        echo "git_branch=\"$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)\""
        echo "git_dirty=\"$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1 || true)\""
    fi
    # SHA256 do bootstrap para verificação pós-build.
    echo "bootstrap_sha256=\"$(sha256sum "$TARGET_FILE" | awk '{print $1}')\""
} > "$MANIFEST"
chmod 0644 "$MANIFEST"

echo "[sync-airootfs] Sincronização concluída."
echo "[sync-airootfs]   $TARGET_FILE ($(wc -c < "$TARGET_FILE") bytes)"
echo "[sync-airootfs]   $MANIFEST"
