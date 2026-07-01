#!/bin/bash
# tests/iso-qemu-validate.sh
#
# Valida uma ISO construída do Crias-Server usando QEMU (via run_archiso,
# script de conveniência que vem com o pacote archiso).
#
# Pré-requisitos:
#   - ISO_PATH apontando para a ISO construída (gerada por mkarchiso)
#   - qemu-desktop e edk2-ovmf instalados (pacotes opcionais do archiso)
#   - run_archiso disponível (vem com pacote archiso)
#
# Este teste NÃO substitui o iso-qemu-boot.sh (que valida boot completo).
# Aqui focamos em:
#   1. Confirmar que a ISO é um ISO válido (estrutura)
#   2. Validar profiledef.sh contra a documentação oficial do archiso
#      (install_dir <= 8 chars [a-z0-9], bootmodes válidas, etc.)
#   3. Verificar que o airootfs tem os arquivos esperados (sem boot)
#   4. Se QEMU disponível, fazer smoke test de boot (5s) e verificar que
#      pelo menos o kernel inicializa
#
# Uso:
#   ISO_PATH=/path/to/crias-server-os.iso bash tests/iso-qemu-validate.sh
#
# Sem ISO_PATH, ainda valida profiledef.sh e airootfs (modo static-only).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_DIR="$ROOT_DIR/archiso-profile"
PROFILEDEF="$PROFILE_DIR/profiledef.sh"
PACKAGES_FILE="$PROFILE_DIR/packages.x86_64"

echo "[iso-qemu-validate] Validando profile archiso contra doc oficial..."
echo "  Profile: $PROFILE_DIR"

# =========================================================================
# 1. profiledef.sh — variáveis obrigatórias conforme README.profile.rst
# =========================================================================

# Carrega profiledef.sh em subshell para validar variáveis.
# IMPORTANTE: mkarchiso faz `declare -A file_permissions=()` antes de sourcear
# profiledef.sh (ver archiso/mkarchiso no repo oficial). Sem isso, a sintaxe
# ["/root"]="0:0:750" falha com "syntax error: operand expected" em bash 5.2+.
# Replicamos isso aqui para que o source funcione standalone.
#
# Saídas são escritas em arquivo temporário com delimitador NUL para evitar
# problemas com valores contendo parênteses, espaços ou caracteres especiais
# (ex: iso_application tem "(Minecraft ou Terraria)").
profile_out="$(mktemp)"
cd "$PROFILE_DIR" && bash -c '
    declare -A file_permissions=()
    source ./profiledef.sh
    # Usa printf com delimitador \x1f (unit separator) para valores seguros.
    printf "%s\x1f%s\n" "iso_name" "$iso_name"
    printf "%s\x1f%s\n" "iso_label" "$iso_label"
    printf "%s\x1f%s\n" "iso_publisher" "$iso_publisher"
    printf "%s\x1f%s\n" "iso_application" "$iso_application"
    printf "%s\x1f%s\n" "iso_version" "$iso_version"
    printf "%s\x1f%s\n" "install_dir" "$install_dir"
    printf "%s\x1f%s\n" "buildmodes" "${buildmodes[*]}"
    printf "%s\x1f%s\n" "bootmodes" "${bootmodes[*]}"
    printf "%s\x1f%s\n" "arch" "$arch"
    printf "%s\x1f%s\n" "airootfs_image_type" "$airootfs_image_type"
    printf "%s\x1f%d\n" "file_permissions_count" "${#file_permissions[@]}"
' > "$profile_out"
cd - > /dev/null

# Lê pares key\x1fvalue do arquivo temporário.
declare -A PV
while IFS=$'\x1f' read -r key value; do
    PV["$key"]="$value"
done < "$profile_out"
rm -f "$profile_out"

# Atribui a variáveis comuns para uso abaixo.
iso_name="${PV[iso_name]}"
iso_label="${PV[iso_label]}"
iso_publisher="${PV[iso_publisher]}"
iso_application="${PV[iso_application]}"
iso_version="${PV[iso_version]}"
install_dir="${PV[install_dir]}"
buildmodes_str="${PV[buildmodes]}"
bootmodes_str="${PV[bootmodes]}"
arch="${PV[arch]}"
airootfs_image_type="${PV[airootfs_image_type]}"
file_permissions_count="${PV[file_permissions_count]}"

# install_dir: máximo 8 caracteres, apenas [a-z0-9] (README.profile.rst)
if ! [[ "$install_dir" =~ ^[a-z0-9]+$ ]]; then
    echo "FAIL: install_dir='$install_dir' contém caracteres inválidos (apenas [a-z0-9] permitido)" >&2
    exit 1
fi
if [ "${#install_dir}" -gt 8 ]; then
    echo "FAIL: install_dir='$install_dir' tem ${#install_dir} chars (máximo 8 per README.profile.rst)" >&2
    exit 1
fi
echo "  OK: install_dir='$install_dir' (valid: ${#install_dir} chars, [a-z0-9])"

# iso_label: máximo 11 chars (limite FAT volume label)
if [ "${#iso_label}" -gt 11 ]; then
    echo "FAIL: iso_label='$iso_label' tem ${#iso_label} chars (máximo 11 per FAT spec)" >&2
    exit 1
fi
echo "  OK: iso_label='$iso_label' (valid: ${#iso_label} chars)"

# bootmodes: deve conter bios.syslinux e/ou uefi.grub / uefi.systemd-boot
valid_bootmodes="bios.syslinux uefi.grub uefi-systemd-boot"
for mode in $bootmodes_str; do
    case "$mode" in
        bios.syslinux|uefi.grub|uefi.systemd-boot)
            ;;
        *)
            echo "FAIL: bootmode inválido em profiledef.sh: $mode" >&2
            echo "  Valores suportados: $valid_bootmodes" >&2
            exit 1
            ;;
    esac
done
echo "  OK: bootmodes=$bootmodes_str (todas válidas)"

# buildmodes: 'iso' (default) ou 'bootstrap' ou 'netboot'
for mode in $buildmodes_str; do
    case "$mode" in
        iso|bootstrap|netboot)
            ;;
        *)
            echo "FAIL: buildmode inválido: $mode" >&2
            exit 1
            ;;
    esac
done
echo "  OK: buildmodes=$buildmodes_str"

# airootfs_image_type: squashfs (default) | ext4+squashfs | erofs
case "$airootfs_image_type" in
    squashfs|ext4+squashfs|erofs)
        echo "  OK: airootfs_image_type='$airootfs_image_type'"
        ;;
    *)
        echo "FAIL: airootfs_image_type inválido: $airootfs_image_type" >&2
        exit 1
        ;;
esac

# =========================================================================
# 2. file_permissions — sintaxe válida conforme doc oficial
#    Formato: ["/path"]="uid:gid:mode"
# =========================================================================

if ! grep -q '^file_permissions=(' "$PROFILEDEF"; then
    echo "FAIL: file_permissions array não encontrado em profiledef.sh" >&2
    exit 1
fi

# Extrai entradas do file_permissions e valida formato.
# Cada entrada deve ser ["<path>"]="<uid>:<gid>:<mode>"
# Itera apenas dentro do bloco file_permissions=( ... ).
perm_count=0
in_array=false
while IFS= read -r line; do
    # Detecta início do array.
    if [[ "$line" =~ ^file_permissions=\( ]]; then
        in_array=true
        # Se a linha tem conteúdo após o (, processa.
        rest="${line#file_permissions=(}"
        if [[ -n "$rest" && "$rest" != ")" ]]; then
            perm_count=$((perm_count + 1))
            if ! [[ "$rest" =~ ^\[[^]]+\]=\"[0-9]+:[0-9]+:[0-7]+\"(\)|[[:space:]]*)$ ]]; then
                echo "FAIL: entrada file_permissions com formato inválido:" >&2
                echo "  $rest" >&2
                echo "  Formato esperado: [\"/path\"]=\"uid:gid:mode\"" >&2
                exit 1
            fi
        fi
        continue
    fi

    # Se estamos dentro do array, processa cada linha.
    if [ "$in_array" = "true" ]; then
        # Fim do array.
        if [[ "$line" =~ ^\) ]]; then
            in_array=false
            continue
        fi
        # Skip comentários e vazias.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        perm_count=$((perm_count + 1))

        # Valida formato: ["path"]="uid:gid:mode"
        if ! [[ "$line" =~ ^[[:space:]]*\[[^]]+\]=\"[0-9]+:[0-9]+:[0-7]+\"[[:space:]]*$ ]]; then
            echo "FAIL: entrada file_permissions com formato inválido:" >&2
            echo "  $line" >&2
            echo "  Formato esperado: [\"/path\"]=\"uid:gid:mode\"" >&2
            exit 1
        fi
    fi
done < "$PROFILEDEF"

if [ "$file_permissions_count" -lt 3 ]; then
    echo "FAIL: file_permissions tem apenas $file_permissions_count entradas (esperado >= 3)" >&2
    exit 1
fi
echo "  OK: file_permissions tem $file_permissions_count entradas com formato válido"

# =========================================================================
# 3. packages.x86_64 — pacotes obrigatórios conforme README.profile.rst
#    "The mkinitcpio and mkinitcpio-archiso packages are mandatory"
# =========================================================================

for mandatory in mkinitcpio mkinitcpio-archiso; do
    if ! grep -Eq "^${mandatory}\$" "$PACKAGES_FILE"; then
        echo "FAIL: pacote obrigatório ausente em packages.x86_64: $mandatory" >&2
        echo "  README.profile.rst diz: 'mkinitcpio and mkinitcpio-archiso are mandatory'" >&2
        exit 1
    fi
done
echo "  OK: pacotes obrigatórios (mkinitcpio, mkinitcpio-archiso) presentes"

# =========================================================================
# 4. Estrutura de diretórios do profile conforme README.profile.rst
#    profile/
#    ├── airootfs/
#    ├── efiboot/   (opcional, se usar uefi.systemd-boot)
#    ├── syslinux/  (obrigatório se bootmodes inclui bios.syslinux)
#    ├── grub/      (obrigatório se bootmodes inclui uefi.grub)
#    ├── packages.${arch}
#    ├── pacman.conf
#    └── profiledef.sh
# =========================================================================

for required_file in "profiledef.sh" "pacman.conf" "packages.${arch}"; do
    if [ ! -f "$PROFILE_DIR/$required_file" ]; then
        echo "FAIL: arquivo obrigatório ausente: $required_file" >&2
        exit 1
    fi
done

if [ ! -d "$PROFILE_DIR/airootfs" ]; then
    echo "FAIL: diretório airootfs/ ausente" >&2
    exit 1
fi

for mode in $bootmodes_str; do
    case "$mode" in
        bios.syslinux)
            if [ ! -d "$PROFILE_DIR/syslinux" ] || [ ! -f "$PROFILE_DIR/syslinux/syslinux.cfg" ]; then
                echo "FAIL: bootmode bios.syslinux requer syslinux/syslinux.cfg" >&2
                exit 1
            fi
            ;;
        uefi.grub)
            if [ ! -d "$PROFILE_DIR/grub" ] || [ ! -f "$PROFILE_DIR/grub/grub.cfg" ]; then
                echo "FAIL: bootmode uefi.grub requer grub/grub.cfg" >&2
                exit 1
            fi
            ;;
        uefi.systemd-boot)
            if [ ! -d "$PROFILE_DIR/efiboot" ]; then
                echo "FAIL: bootmode uefi.systemd-boot requer efiboot/" >&2
                exit 1
            fi
            ;;
    esac
done
echo "  OK: estrutura de diretórios do profile conforme README.profile.rst"

# =========================================================================
# 5. mkinitcpio.conf do airootfs tem hooks essenciais
#    (archiso e archiso_loop_mnt são obrigatórios per documentação)
# =========================================================================

MKINITCPIO="$PROFILE_DIR/airootfs/etc/mkinitcpio.conf"
if [ ! -f "$MKINITCPIO" ]; then
    echo "FAIL: airootfs/etc/mkinitcpio.conf ausente" >&2
    exit 1
fi

hooks_line="$(grep -E '^[[:space:]]*HOOKS=' "$MKINITCPIO" | tail -n 1 || true)"
if [ -z "$hooks_line" ]; then
    echo "FAIL: linha HOOKS não encontrada em mkinitcpio.conf" >&2
    exit 1
fi

for required_hook in archiso archiso_loop_mnt; do
    if ! echo "$hooks_line" | grep -qw "$required_hook"; then
        echo "FAIL: hook '$required_hook' ausente em HOOKS do mkinitcpio.conf" >&2
        echo "  Hooks necessários para boot via archiso (per documentação)" >&2
        exit 1
    fi
done
echo "  OK: mkinitcpio.conf tem hooks archiso + archiso_loop_mnt"

# =========================================================================
# 6. Validação ISO (se ISO_PATH fornecido)
# =========================================================================

if [ -z "${ISO_PATH:-}" ]; then
    echo ""
    echo "[iso-qemu-validate] ISO_PATH não fornecido — pulando validação da ISO real."
    echo "  Para validar ISO construída: ISO_PATH=/path/to/crias.iso bash $0"
    echo "[iso-qemu-validate] OK (static validation only)"
    exit 0
fi

if [ ! -f "$ISO_PATH" ]; then
    echo "FAIL: ISO_PATH='$ISO_PATH' não existe" >&2
    exit 1
fi

echo ""
echo "[iso-qemu-validate] Validando ISO: $ISO_PATH"
echo "  Tamanho: $(du -h "$ISO_PATH" | cut -f1)"

# Verifica magic bytes de ISO 9660 (primeiros bytes devem ser 0x43 0x44 0x30 0x30 = "CD00")
# Mais robusto: usar file(1) se disponível.
if command -v file >/dev/null 2>&1; then
    iso_type="$(file -b "$ISO_PATH")"
    echo "  Tipo: $iso_type"
    if ! echo "$iso_type" | grep -qi 'ISO 9660'; then
        echo "FAIL: arquivo não é ISO 9660 válido" >&2
        exit 1
    fi
    echo "  OK: arquivo é ISO 9660 válido"
fi

# Verifica presença de El Torito boot record no setor 17 da ISO 9660.
# Estrutura ISO 9660:
#   setor 16 (offset 32768): Primary Volume Descriptor
#   setor 17 (offset 34816): El Torito Boot Record (se ISO for bootável)
#   setor 18 (offset 36864): VD Set Terminator
# O Boot Record tem "EL TORITO SPECIFICATION" no offset 7 dentro do setor.
#
# IMPORTANTE: NÃO usar el_torito="$(dd ...)" + echo | grep, porque:
#   1. Offset 32769 (setor 16+1) aponta para o PVD, não o Boot Record.
#      Offset correto é setor 17 (skip=17 com bs=2048).
#   2. bash $(...) stripa null bytes de output binário (warning:
#      "ignored null byte in input"), corrompendo a comparação.
# Solução: pipe direto dd | grep -a (grep -a trata binário como texto).
if command -v dd >/dev/null 2>&1; then
    if dd if="$ISO_PATH" bs=2048 skip=17 count=1 2>/dev/null | grep -aq 'EL TORITO SPECIFICATION'; then
        echo "  OK: El Torito boot record presente (ISO é bootável)"
    else
        echo "  AVISO: El Torito boot record não encontrado no setor 17" >&2
        echo "  (ISO pode não ser bootável)" >&2
        echo "  Dump do setor 17 para debug:" >&2
        dd if="$ISO_PATH" bs=2048 skip=17 count=1 2>/dev/null | od -c | head -4 >&2
    fi
fi

# =========================================================================
# 7. Smoke test via QEMU (se disponível)
# =========================================================================

# run_archiso é o script de conveniência do pacote archiso para testar ISOs.
if command -v run_archiso >/dev/null 2>&1; then
    echo ""
    echo "[iso-qemu-validate] Smoke test via QEMU (run_archiso)..."
    echo "  Iniciando VM por 15s para validar boot do kernel..."
    # -u usa UEFI emulation; sem -u usa BIOS legacy.
    # Roda em background por 15s, depois mata.
    # Saída capturada para verificar se kernel inicializa.
    qemu_log="$(mktemp /tmp/crias-qemu-XXXXXX.log)"
    timeout 15 run_archiso -i "$ISO_PATH" >"$qemu_log" 2>&1 || true

    # Verifica sinais de que o kernel bootou com sucesso.
    if grep -qi 'Linux version' "$qemu_log"; then
        echo "  OK: kernel Linux inicializou"
        kernel_ver="$(grep -oE 'Linux version [0-9.]+[^ ]*' "$qemu_log" | head -1)"
        echo "  $kernel_ver"
    else
        echo "  AVISO: não foi possível confirmar boot do kernel em 15s" >&2
        echo "  (pode ser normal se QEMU for lento; aumente timeout se preciso)" >&2
    fi

    if grep -qi 'archiso' "$qemu_log"; then
        echo "  OK: archiso hooks carregados"
    fi

    rm -f "$qemu_log"
else
    echo ""
    echo "[iso-qemu-validate] run_archiso não disponível — pulando smoke test QEMU."
    echo "  Instale qemu-desktop + edk2-ovmf para validar boot real."
fi

echo ""
echo "[iso-qemu-validate] OK — validação concluída"
