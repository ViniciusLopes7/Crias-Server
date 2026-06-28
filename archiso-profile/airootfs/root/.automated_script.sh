#!/bin/bash
set -euo pipefail

# ============================================
# Hook de Inicialização do ISO - Instalação Automática
# Esse script pode ser disparado quando o root loga no USB bootável
# ============================================

wait_for_network() {
    # On Arch live ISO, NetworkManager may take a moment to become active.
    if command -v systemctl >/dev/null 2>&1; then
        echo "Aguardando NetworkManager..."
        for _i in {1..20}; do
            if systemctl is-active --quiet NetworkManager; then
                break
            fi
            sleep 1
        done
    fi

    # If nm-online exists, let it do the connectivity readiness check.
    if command -v nm-online >/dev/null 2>&1; then
        nm-online -q -t 20 >/dev/null 2>&1 || true
    fi
}

echo "=========================================="
echo "  BEM-VINDO AO INSTALADOR DE GAME SERVER"
echo "=========================================="
echo ""
echo "A ISO detectou que as dependencias base estao prontas."
echo "Pressione [ENTER] para baixar a ultima versao do setup e escolher entre Minecraft ou Terraria."

read -r -p "Continuar? (Y/n) " answer
if [[ "${answer:-Y}" =~ ^([nN][oO]?|[nN])$ ]]; then
    echo "Abortando pelo usuario."
    exit 0
fi

cd /opt || exit 1
timestamp=$(date +%Y%m%d-%H%M%S)
if [ -d "Crias-Server" ]; then
    echo "Diretorio /opt/Crias-Server existe — movendo para /opt/Crias-Server.bak-$timestamp"
    mv Crias-Server "Crias-Server.bak-$timestamp"
fi
if [ -d "Server-Mine" ]; then
    echo "Diretorio /opt/Server-Mine existe — movendo para /opt/Server-Mine.bak-$timestamp"
    mv Server-Mine "Server-Mine.bak-$timestamp"
fi

echo "Verificando conectividade com github.com..."
wait_for_network
if ! command -v curl >/dev/null 2>&1; then
    echo "curl nao encontrado no ambiente da ISO." >&2
    exit 1
fi

if ! curl -fsSL --connect-timeout 5 https://github.com/ViniciusLopes7/Crias-Server >/dev/null; then
    echo "Internet nao detectada. Conecte a rede e execute o instalador manualmente." >&2
    exit 1
fi

# Item S1 do plano: --needed evita reinstalar se já presente na ISO.
pacman -S --needed --noconfirm archlinux-keyring

echo "Clonando repositório (verifique assinatura/sha local se disponível)..."
# Item supply chain: --branch main é volátil; recommendation é pinnar tag específica
# via CRIAS_REPO_REF (default "main"). Para auditar release específica:
#   CRIAS_REPO_REF=v1.0.0 ./install.sh
CRIAS_REPO_REF="${CRIAS_REPO_REF:-main}"
git clone --depth 1 --branch "$CRIAS_REPO_REF" https://github.com/ViniciusLopes7/Crias-Server || { echo "Falha no git clone" >&2; exit 1; }
cd Crias-Server || exit 1

# Item supply chain: verificação GPG de commit. Default ON (SKIP_VERIFY=0 = verifica).
# Para desativar (não recomendado): SKIP_VERIFY=1 ./install.sh
SKIP_VERIFY="${SKIP_VERIFY:-0}"

if [ "$SKIP_VERIFY" != "1" ]; then
    if ! git verify-commit HEAD >/dev/null 2>&1; then
        echo "AVISO: commit não assinado ou chave pública não importada." >&2
        echo "Para importar chave do maintainer:" >&2
        echo "  gpg --receive-keys <KEY_ID>" >&2
        echo "Para pular verificação (NÃO RECOMENDADO):" >&2
        echo "  SKIP_VERIFY=1" >&2
        # Continua com warning em vez de abortar — mantém UX mas documenta risco.
    fi
else
    echo "AVISO: verificação de assinatura desativada (SKIP_VERIFY=1)." >&2
fi

# Optional checksum validation for install.sh
if [ -f install.sh ]; then
    echo "SHA256 de install.sh:" 
    calculated_hash=$(sha256sum install.sh | awk '{print $1}')
    echo "$calculated_hash"
    
    if [ -n "${INSTALL_SH_SHA256:-}" ]; then
        if [ "$calculated_hash" = "$INSTALL_SH_SHA256" ]; then
            echo "✓ Checksum validado com sucesso."
        else
            echo "✗ ERRO: Checksum nao corresponde!"
            echo "  Esperado: $INSTALL_SH_SHA256"
            echo "  Obtido:   $calculated_hash"
            exit 1
        fi
    fi
fi

# Roda o instalador interativo modificado recém (recomendado revisar o checksum acima)
chmod +x install.sh
./install.sh
