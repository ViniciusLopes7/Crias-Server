#!/bin/bash

# ============================================
# Hook de Inicialização do ISO - Instalação Automática
# Esse script pode ser disparado quando o root loga no USB bootável
# ============================================

echo "=========================================="
echo "  BEM-VINDO AO INSTALADOR DO SERVIDOR"
echo "=========================================="
echo ""
echo "A ISO detectou que o Tailscale, Java 21, e dependências já estão instaladas."
echo "Pressione [ENTER] para baixar a última versão do script de setup e inciar o servidor."

read -p "Continuar? " _

cd /opt
if [ -d "Server-Mine" ]; then
    rm -rf Server-Mine
fi

git clone https://github.com/ViniciusLopes7/Server-Mine
cd Server-Mine

# Roda o instalador interativo modificado recém
chmod +x install.sh
./install.sh
