# Diagnostico do Erro: Failed to start Switch Root

## Crias Server OS - ISO Live CD (Arch Linux / Archiso)

**Data:** 2026-04-19
**Autor:** Analise tecnica baseada no repositorio github.com/ViniciusLopes7/Crias-Server

---

## 1. O Erro

Ao tentar bootar a ISO do Crias Server OS em um notebook (ou qualquer maquina), o sistema exibe:

```
[FAILED] Failed to start Switch Root.
You are in emergency mode.
Cannot open access to console, the root account is locked.
```

### Sequencia completa do erro:

1. A BIOS/UEFI encontra o pendrive e carrega o bootloader (GRUB)
2. O menu do GRUB aparece com as opcoes "Crias Server OS" e "Copy to RAM"
3. O kernel (`vmlinuz-linux`) e o initramfs (`initramfs-linux.img`) sao carregados
4. O kernel inicializa e passa o controle ao initramfs
5. O initramfs **nao consegue encontrar** o sistema de arquivos raiz da ISO
6. O servico `initrd-switch-root.service` falha
7. O sistema cai no **emergency mode**
8. Como a conta root esta bloqueada no initramfs, nao e possivel acessar o console

---

## 2. O que funciona (e o que nao funciona)

| Etapa | Status |
|-------|--------|
| Construcao da ISO pelo `mkarchiso` | Funciona (arquivo .iso e gerado) |
| Bootloader GRUB na ISO | Funciona (menu aparece) |
| Bootloader Syslinux (BIOS legacy) | Funciona |
| Carregamento do kernel | Funciona |
| Carregamento do initramfs | Funciona (mas **incompleto**) |
| Initramfs encontra a ISO no pendrive | **FALHA** |
| Switch root para o sistema real | **FALHA** |

---

## 3. Causa Raiz

O problema esta na **ausencia do pacote `archiso`** e dos **hooks do initramfs para Live CD**.

### Contexto: como funciona o boot de um Live CD do Arch

O Arch Linux Live CD usa um mecanismo especial para bootar a partir de uma midia removivel (USB/CD). O initramfs precisa de hooks especiais que sao fornecidos pelo pacote `archiso`. Esses hooks ensinam o initramfs a:

1. **Procurar a ISO** no dispositivo USB/CD pelo UUID (`archisosearchuuid`)
2. **Montar o squashfs** (`airootfs.sfs`) que contem o sistema operacional
3. **Criar um overlay** (camada de escrita em RAM sobre o sistema de leitura)
4. **Executar o switch root** para o sistema real funcionar

### O que aconteceu no seu projeto

O perfil original do archiso (`releng`) inclui os seguintes pacotes essenciais que foram removidos do seu `packages.x86_64`:

| Pacote | Funcao | Status no seu projeto |
|--------|--------|----------------------|
| `archiso` | Hooks do initramfs para Live CD | **AUSENTE** |
| `squashfs-tools` | Manipular o airootfs.sfs | **AUSENTE** |
| `dosfstools` | Suporte a FAT (particoes EFI) | **AUSENTE** |
| `e2fsprogs` | Suporte a ext4 | **AUSENTE** |
| `arch-install-scripts` | Scripts auxiliares | **AUSENTE** |
| `edk2-shell` | Shell UEFI | **AUSENTE** |
| `memtest86+` | Teste de memoria | **AUSENTE** |

Sem o pacote `archiso`, o `mkinitcpio` gera um initramfs **generico**, que so sabe bootar a partir de um disco rigido padrao. Ele nao entende os parametros `archisobasedir` e `archisosearchuuid` que o GRUB passa.

### Alem disso: falta o mkinitcpio.conf

O perfil `releng` original inclui um arquivo `airootfs/etc/mkinitcpio.conf` com os hooks:

```bash
HOOKS=(base udev modconf archiso block filesystems keyboard)
```

O seu projeto **nao possui** esse arquivo, entao mesmo que o pacote `archiso` fosse instalado, o hook pode nao ser incluido no initramfs.

---

## 4. Por que a ISO parece "funcionar"

O `mkarchiso` nao da erro porque:

- Ele instala os pacotes que voce listou sem reclamar
- Ele gera o initramfs com sucesso (só que **sem os hooks do archiso**)
- Ele monta a ISO com o kernel, initramfs e squashfs
- O arquivo `.iso` final é criado normalmente

O problema so aparece no **momento do boot**, quando o initramfs generico nao consegue encontrar o sistema de arquivos raiz.

---

## 5. Como Confirmar o Diagnostico

Se voce tiver acesso a uma maquina com Linux (ou outra ISO Live do Arch), pode verificar a ISO gerada:

```bash
# 1. Monte a ISO
sudo mount -o loop ~/out/crias-server-os-*.iso /mnt

# 2. Verifique os hooks no initramfs
sudo lsinitcpio /mnt/arch/boot/x86_64/initramfs-linux.img | grep archiso
```

**Resultado esperado (ISO quebrada):**
```
# Nada retorna - o hook archiso NAO esta presente
```

**Resultado esperado (ISO corrigida):**
```
hooks/archiso
hooks/archiso_pxe_common
hooks/archiso_pxe_nbd
hooks/archiso_pxe_http
hooks/archiso_loop_mnt
```

---

## 6. Correcao Passo a Passo

### Passo 1: Atualizar o packages.x86_64

Adicione os pacotes essenciais do archiso no inicio do arquivo:

```bash
# === Base archiso (ESSENCIAL - nao remova) ===
archiso
base
linux
linux-firmware
mkinitcpio
syslinux
grub
efibootmgr
dosfstools
e2fsprogs
squashfs-tools
arch-install-scripts
edk2-shell
memtest86+
usbutils

# === Networking ===
networkmanager
tailscale
openssh
curl
wget

# === Minecraft Dependencies ===
jdk21-openjdk
screen
tar
gzip
zstd

# === System utilities ===
nano
vim
htop
iotop
sudo
zram-generator
cpupower
lm_sensors
git
bash-completion
jq
```

**Arquivo:** `archiso-profile/packages.x86_64`

### Passo 2: Criar o mkinitcpio.conf

Crie o arquivo `archiso-profile/airootfs/etc/mkinitcpio.conf`:

```bash
# mkinitcpio.conf para Crias-Server Live ISO

MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev modconf archiso block filesystems keyboard)

# Compressao do initramfs
COMPRESSION="zstd"
```

**Arquivo novo:** `archiso-profile/airootfs/etc/mkinitcpio.conf`

> Nota: o diretorio `airootfs/etc/` pode nao existir no seu projeto. Voce precisa cria-lo.

### Passo 3: Limpar e reconstruir a ISO

```bash
# Limpe completamente o cache anterior
sudo rm -rf /tmp/archiso-tmp

# Reconstrua a ISO do zero
sudo mkarchiso -v -w /tmp/archiso-tmp -o ~/out ~/archiso-minecraft
```

### Passo 4: Verificar a nova ISO

```bash
# Monte a nova ISO e verifique se o hook archiso esta presente
sudo mount -o loop ~/out/crias-server-os-*.iso /mnt
sudo lsinitcpio /mnt/arch/boot/x86_64/initramfs-linux.img | grep archiso

# Desmonte
sudo umount /mnt
```

Se os hooks `archiso*` aparecerem, a ISO esta corrigida.

---

## 7. Possiveis Problemas Adicionais

### Secure Boot

Notebooks modernos tem **Secure Boot** ativado por padrao. O Arch Linux (e sua ISO) **nao assina** os binarios do kernel. Verifique na BIOS/UEFI:

- **Desative Secure Boot** antes de testar
- Mantenha o boot em modo **UEFI** (nao mude para Legacy/CSM a menos que necessario)

### Diferenca entre os dois erros

| Erro | Significado |
|------|-------------|
| Imagem 1 (Switch Root failed) | Initramfs nao encontra o sistema de arquivos - **problema na ISO** |
| Imagem 2 (GRUB menu OK) | Bootloader funciona - **erro esta depois**, no initramfs |

---

## 8. Resumo

| Problema | Causa | Solucao |
|----------|-------|---------|
| Failed to start Switch Root | Initramfs sem hooks do archiso | Adicionar pacote `archiso` ao `packages.x86_64` |
| Root account locked | Consequencia do erro acima (emergency mode) | Corrigir o switch root resolve automaticamente |
| ISO gera mas nao boota | `mkinitcpio.conf` sem hook `archiso` | Criar `airootfs/etc/mkinitcpio.conf` com hooks corretos |
| GRUB funciona mas kernel nao | Parametros `archisosearchuuid` nao sao processados | Incluir hooks do archiso no initramfs |

---

## 9. Referencias

- Documentacao oficial do Archiso: https://wiki.archlinux.org/title/Archiso
- Perfil releng oficial (referencia): `/usr/share/archiso/configs/releng/`
- Hooks do mkinitcpio: https://wiki.archlinux.org/title/Mkinitcpio
- Repositório do projeto: https://github.com/ViniciusLopes7/Crias-Server
