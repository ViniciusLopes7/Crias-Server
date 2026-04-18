#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[arch-smoke] Verificando sintaxe bash..."
mapfile -t scripts < <(find . -type f -name "*.sh" -not -path "./.git/*" | sort)

if [ "${#scripts[@]}" -eq 0 ]; then
    echo "Nenhum script .sh encontrado para validar." >&2
    exit 1
fi

for script in "${scripts[@]}"; do
    bash -n "$script"
done

echo "[arch-smoke] Verificando calculos de tuning por tier..."
# shellcheck source=/dev/null
source shared/lib/hardware-profile.sh
# shellcheck source=/dev/null
source shared/lib/minecraft-tuning.sh
# shellcheck source=/dev/null
source shared/lib/terraria-tuning.sh

for tier in LOW MID HIGH; do
    detect_hardware_profile "$ROOT_DIR" "$tier"

    compute_minecraft_tuning 4096 4 SSD "$tier"
    [[ "$MC_MIN_RAM" =~ ^[0-9]+M$ ]]
    [[ "$MC_MAX_RAM" =~ ^[0-9]+M$ ]]
    [[ "$MC_SERVICE_MEMORY_MAX_MB" =~ ^[0-9]+$ ]]

    compute_terraria_tuning 4096 4 SSD "$tier"
    [[ "$TT_SERVICE_MEMORY_MAX_MB" =~ ^[0-9]+$ ]]

done

echo "[arch-smoke] Verificando placeholders de service..."
grep -q "__SERVER_USER__" minecraft/minecraft.service
grep -q "__SERVER_DIR__" minecraft/minecraft.service
grep -q "__MEMORY_MAX_MB__" minecraft/minecraft.service
grep -q "__SERVER_USER__" terraria/terraria.service
grep -q "__SERVER_DIR__" terraria/terraria.service
grep -q "__MEMORY_MAX_MB__" terraria/terraria.service

echo "[arch-smoke] Verificando ausencia de arquivos legados na raiz..."
for legacy in start-server.sh mc-manager.sh backup-cron.sh setup-cron.sh minecraft.service; do
    if [ -e "$legacy" ]; then
        echo "Arquivo legado encontrado na raiz: $legacy" >&2
        exit 1
    fi
done

echo "[arch-smoke] Verificando organizacao de imagens..."
for img in EscudoCrias.png TronoCrias.png server-icon.png; do
    if [ -e "$img" ]; then
        echo "Imagem ainda esta na raiz: $img" >&2
        exit 1
    fi
    if [ ! -f "assets/images/branding/$img" ]; then
        echo "Imagem esperada nao encontrada: assets/images/branding/$img" >&2
        exit 1
    fi
done

echo "[arch-smoke] OK"
