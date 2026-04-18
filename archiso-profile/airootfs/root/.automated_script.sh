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

read -r -p "Continuar? " _

cd /opt || exit 1
if [ -d "Crias-Server" ]; then
    rm -rf Crias-Server
fi
if [ -d "Server-Mine" ]; then
    rm -rf Server-Mine
fi

git clone https://github.com/ViniciusLopes7/Crias-Server
cd Crias-Server || exit 1

# Roda o instalador interativo modificado recém
chmod +x install.sh
./install.sh
