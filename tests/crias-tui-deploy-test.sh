#!/bin/bash
# Regression tests for early TUI deploy and read-only diagnosis.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# The TUI fallback works without a TTY or the gum dependency.
choice="$(printf "2\n" | bash -c 'source "$1"; hub_choose "Teste" "Primeiro" "Segundo"' _ "$root/crias-tui.sh")"
[ "$choice" = "Segundo" ] || { echo "FAIL: menu numerado" >&2; exit 1; }
bash "$root/crias-tui.sh" --doctor >/dev/null
bash "$root/crias-tui.sh" --help | grep -q -- "--doctor"
# O submenu Minecraft deve expor visoes sem esconder logs completos.
for option in "logs recent" "logs alerts" "logs boot" "logs follow"; do
    grep -Fq "$option" "$root/crias-tui.sh" || { echo "FAIL: opcao TUI ausente: $option" >&2; exit 1; }
done

# Hub must expose the core administrative flows, not just raw CLI actions.
for item in "🔄 Atualizações" "crias-update" "arch-check" "arch-apply" "📁 Arquivos" "🎙️ Voice Chat" "files" "setup-files" "voicechat status" "voicechat set-port" "voicechat edit" "voicechat network" "Pasta principal do servidor" "Mods do servidor" "Configuracoes (config)" "Mundo atual" "Backups locais" "Logs locais"; do
    grep -Fq "$item" "$root/crias-tui.sh" || { echo "FAIL: falta no Hub: $item" >&2; exit 1; }
done

# Main-menu priority should remain consistent with the tasks operators use.
mapfile -t menu_order < <(
    grep -F -A9 'choice=$(hub_choose "Menu principal — Minecraft"' "$root/crias-tui.sh" |
        tail -n 9 | sed -E 's/^[[:space:]]+"([^"]+)".*/\1/'
)
expected_order=("🎮 Servidor" "💾 Backup" "📁 Arquivos" "🎙️ Voice Chat" \
    "📊 Monitoramento" "🔄 Atualizações" "⚙️  Sistema" "🩺 Diagnóstico" "🚪 Sair")
[ "\${#menu_order[@]}" = "\${#expected_order[@]}" ] || {
    echo "FAIL: quantidade de itens do menu principal mudou" >&2; exit 1
}
for idx in "\${!expected_order[@]}"; do
    [ "\${menu_order[$idx]}" = "\${expected_order[$idx]}" ] || {
        echo "FAIL: ordem inesperada no menu, posicao $idx" >&2; exit 1
    }
done
# The border must close on BOTH text rows in the Hub header.
[ "$(grep -Fc "printf '%b│%b %-42s %b│%b" "$root/crias-tui.sh")" = 2 ] || {
    echo "FAIL: moldura do cabecalho nao fecha nas duas linhas" >&2; exit 1
}

# Deploy happens before the heavyweight stack installer begins.
first="$(grep -n "^    deploy_crias_tui$" "$root/install.sh" | head -n1 | cut -d: -f1)"
stack="$(grep -n "^    run_selected_stack_installer$" "$root/install.sh" | head -n1 | cut -d: -f1)"
[ -n "$first" ] && [ "$first" -lt "$stack" ] || { echo "FAIL: deploy tardio" >&2; exit 1; }

# Missing source or a copy failure must never be reported as success.
source "$root/install.sh"
DRY_RUN=false
old_dir="$SCRIPT_DIR"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"; _crias_cleanup_temps' EXIT
SCRIPT_DIR="$tmp"
if deploy_crias_tui >/dev/null 2>&1; then
    echo "FAIL: fonte ausente foi aceita" >&2; exit 1
fi
SCRIPT_DIR="$old_dir"
install() { return 1; }
if deploy_crias_tui >/dev/null 2>&1; then
    echo "FAIL: copia mal-sucedida foi aceita" >&2; exit 1
fi
echo "OK: TUI antecipado, menu fallback, diagnostico e fail-closed"
