#!/bin/bash
# archiso-profile/airootfs/root/.automated_script.sh
#
# Hook de inicialização do ISO — roda automaticamente quando o root loga no
# tty1 do live USB (ver .bash_profile). Inicia o instalador do Crias-Server.
#
# Estratégia "pronto pra uso":
#   1. Tenta usar a cópia embutida da ISO em /opt/crias-server/install.sh
#      (populado por sync-airootfs.sh no build da ISO).
#   2. Se não existir (ISO antiga / build manual sem sync), faz git clone do
#      GitHub como fallback.
#   3. Antes de rodar o install.sh, valida conectividade (algumas operações
#      do install.sh precisam de internet: pacman, downloads de mods, etc.).
#
# Variáveis de ambiente que controlam o comportamento:
#   CRIAS_SKIP_AUTOSTART=1        — não roda este script (ver .bash_profile)
#   CRIAS_REPO_REF=<branch|tag>   — ref do git a clonar no fallback (default: main)

set -euo pipefail

# ============================================
# Helpers
# ============================================

log()  { printf '[CRIAS] %s\n' "$*"; }
warn() { printf '[CRIAS][AVISO] %s\n' "$*" >&2; }
err()  { printf '[CRIAS][ERRO] %s\n' "$*" >&2; }

wait_for_network() {
    # No Arch live ISO, NetworkManager pode demorar alguns segundos.
    if command -v systemctl >/dev/null 2>&1; then
        log "Aguardando NetworkManager..."
        for _i in {1..20}; do
            if systemctl is-active --quiet NetworkManager; then
                break
            fi
            sleep 1
        done
    fi
    # nm-online faz readiness check real (DHCP + gateway reachable).
    if command -v nm-online >/dev/null 2>&1; then
        nm-online -q -t 20 >/dev/null 2>&1 || true
    fi
}

has_internet() {
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsSL --connect-timeout 5 https://github.com >/dev/null 2>&1
}

# ============================================
# Boot screen
# ============================================

echo "=========================================="
echo "  BEM-VINDO AO INSTALADOR DE GAME SERVER"
echo "  Crias-Server (Minecraft ou Terraria)"
echo "=========================================="
echo ""

# ============================================
# Detecta fonte do instalador (embedded vs clone)
# ============================================

EMBEDDED_DIR="/opt/crias-server"
EMBEDDED_INSTALL="$EMBEDDED_DIR/install.sh"

if [ -f "$EMBEDDED_INSTALL" ]; then
    log "Instalador embutido detectado em $EMBEDDED_INSTALL"
    log "Manifesto da ISO:"
    if [ -f "$EMBEDDED_DIR/.sync-manifest" ]; then
        sed 's/^/  /' "$EMBEDDED_DIR/.sync-manifest" || true
    fi
    INSTALL_DIR="$EMBEDDED_DIR"
    INSTALL_SCRIPT="$EMBEDDED_INSTALL"
    SOURCE_MODE="embedded"
else
    log "Instalador não embutido na ISO — vou clonar do GitHub (fallback)."
    INSTALL_DIR=""
    INSTALL_SCRIPT=""
    SOURCE_MODE="clone"
fi

# ============================================
# Confirmação inicial do usuário
# ============================================

echo ""
echo "Pressione [ENTER] para iniciar o setup e escolher entre Minecraft ou Terraria."
echo "Se quiser apenas o shell do live ISO, cancele e defina CRIAS_SKIP_AUTOSTART=1 no próximo boot."

read -r -p "Continuar? (Y/n) " answer
if [[ "${answer:-Y}" =~ ^([nN][oO]?|[nN])$ ]]; then
    log "Abortado pelo usuário. Shell do live ISO disponível."
    exit 0
fi

# ============================================
# Prepara diretório de trabalho (clone fallback)
# ============================================

cd /opt || exit 1

if [ "$SOURCE_MODE" = "clone" ]; then
    timestamp=$(date +%Y%m%d-%H%M%S)
    if [ -d "Crias-Server" ]; then
        log "Diretório /opt/Crias-Server existe — movendo para /opt/Crias-Server.bak-$timestamp"
        mv Crias-Server "Crias-Server.bak-$timestamp"
    fi
    if [ -d "Server-Mine" ]; then
        log "Diretório /opt/Server-Mine existe — movendo para /opt/Server-Mine.bak-$timestamp"
        mv Server-Mine "Server-Mine.bak-$timestamp"
    fi

    log "Verificando conectividade com github.com..."
    wait_for_network
    if ! has_internet; then
        err "Internet não detectada. A ISO atual não tem o instalador embutido,"
        err "e não é possível clonar o repositório. Conecte-se à rede e tente novamente."
        err "Se você tem uma ISO com instalador embutido, considere regerar a ISO"
        err "com 'bash archiso-profile/sync-airootfs.sh' antes do mkarchiso."
        exit 1
    fi

    # Atualiza keyring (item S1 do plano: --needed evita reinstalar se já presente).
    log "Atualizando archlinux-keyring (pode demorar)..."
    pacman -S --needed --noconfirm archlinux-keyring || warn "Falha ao atualizar keyring; continuando."

    log "Clonando repositório do GitHub..."
    CRIAS_REPO_REF="${CRIAS_REPO_REF:-main}"
    # Validate CRIAS_REPO_REF: allow tag vX.Y.Z or 40-hex commit SHA.
    # Impede injeção via kernel cmdline ou ISO maliciosa apontando para branch
    # arbitrária do mesmo repositório.
    case "$CRIAS_REPO_REF" in
        main) ;;
        v[0-9]*.[0-9]*.[0-9]*) ;;
        [a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]) ;;
        *)
            err "CRIAS_REPO_REF inválido: $CRIAS_REPO_REF"
            err "Valores aceitos: main | tag vX.Y.Z | commit SHA (40 hex)"
            exit 1
            ;;
    esac
    if ! git clone --depth 1 --branch "$CRIAS_REPO_REF" https://github.com/ViniciusLopes7/Crias-Server; then
        err "Falha no git clone. Verifique rede e tente manualmente:"
        err "  git clone https://github.com/ViniciusLopes7/Crias-Server"
        exit 1
    fi
    cd Crias-Server || { err "Falha ao entrar em Crias-Server"; exit 1; }

    INSTALL_DIR="$(pwd)"
    INSTALL_SCRIPT="$INSTALL_DIR/install.sh"
fi

if [ ! -f "$INSTALL_SCRIPT" ]; then
    err "install.sh não encontrado em $INSTALL_SCRIPT"
    exit 1
fi

# Aviso de conectividade para o install.sh
if ! has_internet; then
    warn "Internet não detectada. Algumas etapas do install.sh podem falhar:"
    warn "  - Instalação do Tailscale (defina INSTALL_TAILSCALE=false para pular)"
    warn "  - Download de mods/modpack (MINECRAFT_INSTALL_MODPACK=false)"
    warn "  - Download do crias-agent (INSTALL_AGENT=false)"
    warn "Continuando mesmo assim..."
fi

chmod +x "$INSTALL_SCRIPT"
log "Executando $INSTALL_SCRIPT ..."
cd "$INSTALL_DIR" || { err "Falha ao cd para $INSTALL_DIR"; exit 1; }
exec ./install.sh
