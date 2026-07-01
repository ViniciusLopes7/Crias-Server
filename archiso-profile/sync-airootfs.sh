#!/bin/bash
# archiso-profile/sync-airootfs.sh
#
# Sincroniza os scripts do Crias-Server do repo (raiz) para dentro do airootfs
# da ISO, em /opt/crias-server/. Assim a ISO nasce "pronta pra uso": o usuário
# dá boot e o instalador já está disponível em /opt/crias-server/install.sh,
# sem precisar de internet para clonar o repo do GitHub.
#
# Este script deve ser rodado ANTES do `mkarchiso` (no CI ou localmente).
#
# Items incluídos no airootfs:
#   - install.sh, config.env, packages.lock
#   - shared/lib/* (bibliotecas bash)
#   - minecraft/* (stack installer + manager + service template)
#   - terraria/* (espelho do minecraft)
#   - assets/images/branding/* (banner e escudo usados no print_header)
#
# Items NÃO incluídos (ficam de fora; baixados sob demanda pelo install.sh):
#   - tailscale (pacote pacman; removido do packages.x86_64)
#   - discord-agent/, discord-bot/ (instalados via GitHub release se INSTALL_AGENT=true)
#   - docs/, tests/, .github/ (não necessários em runtime)
#   - archiso-profile/ (auto-referência)
#
# Uso:
#   bash archiso-profile/sync-airootfs.sh
#
# Saída: preenche archiso-profile/airootfs/opt/crias-server/ com os arquivos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$SCRIPT_DIR/airootfs/opt/crias-server"

echo "[sync-airootfs] Repo root: $REPO_ROOT"
echo "[sync-airootfs] Target:    $TARGET"

# Limpa target anterior para evitar resíduos de arquivos deletados no repo.
rm -rf "$TARGET"
mkdir -p "$TARGET"

# --- Lista branca do que copiar (paths relativos ao repo root) ---
# Mantenha sincronizado com o teste tests/iso-embedded-scripts-validate.sh.
COPY_PATHS=(
    "install.sh"
    "config.env"
    "packages.lock"
    "shared"
    "minecraft"
    "terraria"
    "assets/images/branding"
)

for p in "${COPY_PATHS[@]}"; do
    src="$REPO_ROOT/$p"
    if [ ! -e "$src" ]; then
        echo "[sync-airootfs] AVISO: $src não existe; pulando." >&2
        continue
    fi
    # Cria dir pai no target.
    mkdir -p "$TARGET/$(dirname "$p")"
    cp -a "$src" "$TARGET/$p"
done

# Garante permissões executáveis nos .sh que precisam (mkarchiso respeita
# file_permissions do profiledef.sh, mas também precisamos que estejam x no
# source para não depender da metadata).
find "$TARGET" -name '*.sh' -type f -exec chmod 0755 {} +

# Marca arquivos de config como 0644 (não-executáveis).
chmod 0644 "$TARGET/config.env" 2>/dev/null || true
chmod 0644 "$TARGET/packages.lock" 2>/dev/null || true

# Escreve um manifesto para auditoria (qual commit gerou esta ISO).
{
    echo "# Gerado por sync-airootfs.sh — não editar manualmente."
    echo "synced_at=\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    if command -v git >/dev/null 2>&1; then
        echo "git_commit=\"$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)\""
        echo "git_short=\"$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)\""
        echo "git_branch=\"$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)\""
        echo "git_dirty=\"$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null | head -1 || true)\""
    fi
} > "$TARGET/.sync-manifest"

echo "[sync-airootfs] Sincronização concluída. Conteúdo:"
( cd "$TARGET" && find . -type f | sort | sed 's|^\./|  |' )
echo "[sync-airootfs] Manifesto escrito em $TARGET/.sync-manifest"
