#!/bin/bash

# ============================================
# Hook de Inicialização do ISO - Instalação Automática
# Esse script pode ser disparado quando o root loga no USB bootável
# ============================================

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
if ! ping -n 1 github.com >/dev/null 2>&1; then
    echo "Internet nao detectada. Conecte a rede e execute o instalador manualmente." >&2
    exit 1
fi

echo "Clonando repositório (verifique assinatura/sha local se disponível)..."
git clone https://github.com/ViniciusLopes7/Crias-Server || { echo "Falha no git clone" >&2; exit 1; }
cd Crias-Server || exit 1

# Mostra checksum do instalador para verificar manualmente (opcional)
if [ -f install.sh ]; then
    echo "SHA256 de install.sh:" 
    sha256sum install.sh || true
fi

# Roda o instalador interativo modificado recém (recomendado revisar o checksum acima)
chmod +x install.sh
./install.sh
