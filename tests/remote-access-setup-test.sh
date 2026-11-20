#!/bin/bash
# Contraprovas do acesso remoto antes do Minecraft e do anti-loop de OOM.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/install.sh"
tmp="$(mktemp -d)"
trap '_crias_cleanup_temps; rm -rf -- "$tmp"' EXIT
: > "$tmp/calls"
MOCK_TS_STATE=Running

# Nao modifica network ou systemd: todos os comandos remotos sao stubs.
systemctl() {
    if [ "$*" = "is-active --quiet tailscaled" ]; then return 0; fi
    echo "systemctl inesperado: $*" >&2
    return 1
}
tailscale() {
    printf "%s\n" "$*" >> "$tmp/calls"
    case "$*" in
        "status --json") printf '{"BackendState":"%s"}\n' "$MOCK_TS_STATE" ;;
        "ip -4") printf "100.101.102.103\n" ;;
        *) echo "comando tailscale inesperado: $*" >&2; return 1 ;;
    esac
}

INSTALL_TAILSCALE=true
DRY_RUN=false
NON_INTERACTIVE=true
configure_tailscale_login_if_enabled > "$tmp/out"
grep -q "100.101.102.103" "$tmp/out"
! grep -q "^up" "$tmp/calls"

# Na instalacao automatica nao se tenta autenticar nem bloqueia downloads.
MOCK_TS_STATE=NeedsLogin
: > "$tmp/calls"
configure_tailscale_login_if_enabled > "$tmp/out"
grep -q "nao autenticado" "$tmp/out"
! grep -q "^up" "$tmp/calls"

# Se desativado, nao toca no daemon ou nas credenciais existentes.
INSTALL_TAILSCALE=false
: > "$tmp/calls"
configure_tailscale_login_if_enabled > "$tmp/out"
[ ! -s "$tmp/calls" ]

# A autorizacao do navegador nunca usa auth key persistida no config.env.
grep -Fq 'tui_confirm "Autenticar Tailscale agora?' "$root/install.sh"
grep -Fq "timeout --foreground 180s tailscale up --timeout=180s" "$root/install.sh"
! grep -Eq '^TAILSCALE_AUTH_KEY=' "$root/config.env"

# Seguranca do lifecycle: SSH e login Tailscale antecedem stack instalavel.
line_tailscale="$(grep -n '^    configure_tailscale_login_if_enabled$' "$root/install.sh" | cut -d: -f1)"
line_ssh="$(grep -n '^    install_ssh_if_enabled$' "$root/install.sh" | cut -d: -f1)"
line_stack="$(grep -n '^    run_selected_stack_installer$' "$root/install.sh" | cut -d: -f1)"
[ "$line_tailscale" -lt "$line_ssh" ] && [ "$line_ssh" -lt "$line_stack" ]

# Fail-closed: OOM/crash nao dispara nova JVM ate start manual.
unit="$root/minecraft/minecraft.service"
grep -qx "Restart=no" "$unit"
grep -qx "RestartSec=30s" "$unit"
grep -qx "OOMPolicy=stop" "$unit"
grep -qx "StartLimitIntervalSec=300s" "$unit"
grep -qx "OOMScoreAdjust=200" "$unit"
! grep -qx "StartLimitIntervalSec=infinity" "$unit"
grep -qx "StartLimitBurst=3" "$unit"

echo "OK: Tailscale idempotente/não interativo, SSH antecipado e proteção anti-loop OOM"
