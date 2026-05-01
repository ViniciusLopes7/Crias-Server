#!/bin/bash

set -euo pipefail

usage() {
    echo "Uso: $0 <caminho-da-iso> [timeout-segundos]" >&2
    echo "Ou:  $0 --deep-smoke <caminho-da-iso> [timeout-segundos]" >&2
    echo "Ou:  $0 --analyze-log <arquivo-log>" >&2
}

sanitize_log_file() {
    local raw_log_file="$1"
    local clean_log_file="$2"

    if command -v perl >/dev/null 2>&1; then
        # Remove sequencias ANSI/OSC para matching deterministico.
        perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\e\][^\a]*(\a|\e\\)//g; s/\eP.*?\e\\//g' "$raw_log_file" > "$clean_log_file" || cp "$raw_log_file" "$clean_log_file"
    else
        cp "$raw_log_file" "$clean_log_file"
    fi
}

validate_qemu_log() {
    local raw_log_file="$1"
    local clean_log_file="$2"

    sanitize_log_file "$raw_log_file" "$clean_log_file"

    if grep -Eqi 'Failed to start Switch Root|You are in emergency mode|dropped into an emergency shell|Failed to mount .* on real root|ERROR: Failed to mount|Cannot open access to console|Kernel panic|Unable to find device with label|Timed out waiting for device' "$clean_log_file"; then
        echo "Falha de boot detectada no log do QEMU." >&2
        return 1
    fi

    if ! grep -Eqi 'archiso login:|archlinux login:|[A-Za-z0-9._-]+ login:|Welcome to .*Arch Linux|Reached target .*Multi-User|Reached target .*Login Prompts|Please configure the system|Please enter the new timezone|root@archiso|Server@archiso' "$clean_log_file"; then
        echo "Sem marcador de boot completo detectado no log do QEMU." >&2
        return 1
    fi

    return 0
}

if [ "${1:-}" = "--analyze-log" ]; then
    if [ "$#" -ne 2 ]; then
        usage
        exit 1
    fi

    ANALYZE_LOG_FILE="$2"

    if [ ! -f "$ANALYZE_LOG_FILE" ]; then
        echo "Arquivo de log nao encontrado: $ANALYZE_LOG_FILE" >&2
        exit 1
    fi

    WORK_DIR="$(mktemp -d)"
    CLEAN_LOG_FILE="$WORK_DIR/qemu-boot.clean.log"
    trap 'rm -rf "$WORK_DIR"' EXIT

    if ! validate_qemu_log "$ANALYZE_LOG_FILE" "$CLEAN_LOG_FILE"; then
        tail -n 120 "$ANALYZE_LOG_FILE" >&2
        exit 1
    fi

    echo "[iso-qemu-boot] OK (analise de log)"
    exit 0
fi

MODE="basic"
if [ "${1:-}" = "--deep-smoke" ]; then
    MODE="deep"
    shift
fi

if [ "$#" -lt 1 ]; then
    usage
    exit 1
fi

ISO_FILE="$1"
BOOT_TIMEOUT="${2:-240}"

if [ ! -f "$ISO_FILE" ]; then
    echo "Arquivo ISO nao encontrado: $ISO_FILE" >&2
    exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "qemu-system-x86_64 nao encontrado no ambiente." >&2
    exit 1
fi

if ! command -v bsdtar >/dev/null 2>&1; then
    echo "bsdtar nao encontrado no ambiente." >&2
    exit 1
fi

if [ "$MODE" = "deep" ] && ! command -v expect >/dev/null 2>&1; then
    echo "expect nao encontrado no ambiente para --deep-smoke." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WORK_DIR="$(mktemp -d)"
LOG_FILE="$WORK_DIR/qemu-boot.log"
trap 'rm -rf "$WORK_DIR"' EXIT

kernel_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/boot/x86_64/vmlinuz-linux$' | head -n 1 || true)"
initramfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/boot/x86_64/initramfs-linux\.img$' | head -n 1 || true)"
squashfs_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '.*/x86_64/airootfs\.sfs$' | head -n 1 || true)"
syslinux_cfg_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '(^|/)syslinux/(archiso_sys-linux\.cfg|syslinux\.cfg)$' | head -n 1 || true)"
grub_cfg_rel="$(bsdtar -tf "$ISO_FILE" | grep -E '(^|/)grub/grub\.cfg$' | head -n 1 || true)"

if [ -z "$kernel_rel" ] || [ -z "$initramfs_rel" ] || [ -z "$squashfs_rel" ]; then
    echo "Kernel, initramfs ou squashfs nao encontrados na ISO." >&2
    exit 1
fi

bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$kernel_rel" "$initramfs_rel"

if [ -n "$syslinux_cfg_rel" ]; then
    bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$syslinux_cfg_rel"
fi

if [ -n "$grub_cfg_rel" ]; then
    bsdtar -xf "$ISO_FILE" -C "$WORK_DIR" "$grub_cfg_rel"
fi

KERNEL_FILE="$WORK_DIR/$kernel_rel"
INITRAMFS_FILE="$WORK_DIR/$initramfs_rel"

install_dir="${kernel_rel%/boot/x86_64/vmlinuz-linux}"
install_dir="${install_dir#/}"

if [ -z "$install_dir" ] || [ "$install_dir" = "$kernel_rel" ]; then
    echo "Nao foi possivel detectar archisobasedir a partir do kernel na ISO." >&2
    exit 1
fi

cmdline_from_iso=""

if [ -n "$syslinux_cfg_rel" ] && [ -f "$WORK_DIR/$syslinux_cfg_rel" ]; then
    cmdline_from_iso="$(sed -nE 's/^[[:space:]]*APPEND[[:space:]]+(.+archisobasedir=[^[:space:]]+.*)$/\1/p' "$WORK_DIR/$syslinux_cfg_rel" | head -n 1 || true)"
fi

if [ -z "$cmdline_from_iso" ] && [ -n "$grub_cfg_rel" ] && [ -f "$WORK_DIR/$grub_cfg_rel" ]; then
    cmdline_from_iso="$(sed -nE 's/^[[:space:]]*linux[[:space:]]+[^[:space:]]+[[:space:]]+(.+archisobasedir=[^[:space:]]+.*)$/\1/p' "$WORK_DIR/$grub_cfg_rel" | head -n 1 || true)"
fi

if echo "$cmdline_from_iso" | grep -q '%ARCHISO_UUID%\|%INSTALL_DIR%\|%ARCH%'; then
    cmdline_from_iso=""
fi

qemu_kernel_args=()

if [ -n "$cmdline_from_iso" ]; then
    # Reaproveita exatamente os parametros resolvidos no bootloader da ISO.
    qemu_kernel_args+=("$cmdline_from_iso")
else
    if ! command -v blkid >/dev/null 2>&1; then
        echo "blkid nao encontrado no ambiente para fallback de parametros." >&2
        exit 1
    fi

    iso_label="$(blkid -o value -s LABEL "$ISO_FILE" 2>/dev/null || true)"
    iso_uuid="$(blkid -o value -s UUID "$ISO_FILE" 2>/dev/null || true)"

    qemu_kernel_args+=("archisobasedir=${install_dir}")
    if [ -n "$iso_label" ]; then
        qemu_kernel_args+=("archisolabel=${iso_label}")
    elif [ -n "$iso_uuid" ]; then
        qemu_kernel_args+=("archisosearchuuid=${iso_uuid}")
    else
        echo "Nao foi possivel detectar LABEL/UUID da ISO para fallback." >&2
        exit 1
    fi
fi

qemu_kernel_args+=(
    "console=tty0"
    "console=ttyS0,115200"
    "loglevel=4"
    "rd.systemd.show_status=1"
    "systemd.log_level=info"
    "systemd.log_target=console"
)

kernel_cmdline="${qemu_kernel_args[*]}"

echo "[iso-qemu-boot] Usando archisobasedir=${install_dir}"
if [ -n "$cmdline_from_iso" ]; then
    echo "[iso-qemu-boot] Params base extraidos do bootloader da ISO."
else
    echo "[iso-qemu-boot] Params base via fallback de LABEL/UUID da ISO."
fi
echo "[iso-qemu-boot] Kernel cmdline: $kernel_cmdline"
if [ "$MODE" = "deep" ]; then
    echo "[iso-qemu-boot] Deep smoke em QEMU (login + comandos, timeout=${BOOT_TIMEOUT}s)..."
else
    echo "[iso-qemu-boot] Boot smoke em QEMU (timeout=${BOOT_TIMEOUT}s)..."
fi

set +e

if [ "$MODE" = "deep" ]; then
    export QEMU_BOOT_TIMEOUT="$BOOT_TIMEOUT"
    export ISO_FILE
    export KERNEL_FILE
    export INITRAMFS_FILE
    export KERNEL_CMDLINE="$kernel_cmdline"

    timeout "$BOOT_TIMEOUT" expect <<'EOF' > "$LOG_FILE" 2>&1
set timeout $env(QEMU_BOOT_TIMEOUT)
log_user 1

spawn qemu-system-x86_64 -m 2048 -cdrom $env(ISO_FILE) -kernel $env(KERNEL_FILE) -initrd $env(INITRAMFS_FILE) -append $env(KERNEL_CMDLINE) -nographic -no-reboot -monitor none -serial stdio

expect {
    -re {(?i)(archiso|archlinux|[A-Za-z0-9._-]+) login:} {}
    timeout { send_user "Timeout aguardando prompt de login\n"; exit 21 }
}

send -- "Server\r"

expect {
    -re {(?i)password:} {}
    timeout { send_user "Timeout aguardando prompt de senha\n"; exit 22 }
}

send -- "crias\r"

expect {
    -re {Server@.*[$#] } {}
    -re {root@.*# } {}
    timeout { send_user "Timeout aguardando shell apos login\n"; exit 23 }
}

send -- "id -un\r"
expect {
    -re {(\r\n|^)(Server|root)(\r\n|\n)} {}
    timeout { send_user "Timeout validando comando id -un\n"; exit 24 }
}

send -- "test -x /root/.automated_script.sh; echo AUTOMATED_SCRIPT_OK:$?\r"
expect {
    -re {AUTOMATED_SCRIPT_OK:0} {}
    timeout { send_user "Timeout validando /root/.automated_script.sh\n"; exit 25 }
}

send -- "exit\r"
expect {
    -re {(?i)(archiso|archlinux|[A-Za-z0-9._-]+) login:} { exit 0 }
    eof { exit 0 }
    timeout { exit 0 }
}
EOF
    qemu_status=$?
else
    timeout "$BOOT_TIMEOUT" qemu-system-x86_64 \
        -m 2048 \
        -cdrom "$ISO_FILE" \
        -kernel "$KERNEL_FILE" \
        -initrd "$INITRAMFS_FILE" \
        -append "$kernel_cmdline" \
        -nographic \
        -no-reboot \
        -monitor none \
        -serial stdio > "$LOG_FILE" 2>&1
    qemu_status=$?
fi

set -e

cp "$LOG_FILE" "$ROOT_DIR/qemu-boot.log" || true

CLEAN_LOG_FILE="$WORK_DIR/qemu-boot.clean.log"
if ! validate_qemu_log "$LOG_FILE" "$CLEAN_LOG_FILE"; then
    tail -n 120 "$LOG_FILE" >&2
    exit 1
fi

if [ "$qemu_status" -ne 0 ] && [ "$qemu_status" -ne 124 ]; then
    echo "QEMU retornou status inesperado: $qemu_status" >&2
    tail -n 120 "$LOG_FILE" >&2
    exit 1
fi

echo "[iso-qemu-boot] OK"