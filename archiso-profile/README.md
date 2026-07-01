# Gerador de ISO (Archiso) para o Crias-Server

A ISO gerada pelo Crias-Server é **pronta pra uso**: ao dar boot, o instalador
já está embutido em `/opt/crias-server/` e roda automaticamente no primeiro
login do root. Dependências base (Java 21, NetworkManager, Tailscale,
ferramentas de sistema) já vêm pré-instaladas para acelerar o setup.

> **v1.1.0**: ISO agora é "pronta pra uso" — instalador embutido em
> `/opt/crias-server/`. Tailscale voltou a ser pré-instalado na ISO
> (mantido em `packages.x86_64`) para garantir disponibilidade mesmo sem
> internet no primeiro boot.

## Como a ISO funciona

```
┌─────────────────────────────────────────────────────────────┐
│  Boot do live USB                                            │
│    └─> login automático como root no tty1                    │
│        └─> /root/.bash_profile executa /root/.automated_script.sh
│                                                              │
│  /root/.automated_script.sh:                                 │
│    1. Detecta /opt/crias-server/install.sh (EMBEDDED)        │
│       ├─ se existir: roda direto (SEM precisar de internet   │
│       │              para baixar o instalador)               │
│       └─ se não existir: git clone GitHub (fallback)         │
│    2. Avisa se internet está indisponível (algumas etapas    │
│       do install.sh precisam: pacman, downloads)             │
│    3. Executa install.sh                                     │
└─────────────────────────────────────────────────────────────┘
```

## Como construir a ISO

### Pré-requisitos
- Arch Linux hospedeiro (ou container `archlinux:base-devel`)
- `archiso`, `git`, `grub` instalados
- ~3GB livres em disco + RAM

### Passo a passo

1. **Instale o archiso** (se ainda não tiver):
   ```bash
   sudo pacman -S archiso
   ```

2. **Sincronize os scripts do repo para dentro do airootfs**:
   ```bash
   # A partir da raiz do repo Crias-Server
   bash archiso-profile/sync-airootfs.sh
   ```
   Este passo copia `install.sh`, `config.env`, `shared/lib/*`, `minecraft/*`,
   `terraria/*` e `assets/images/branding/*` para dentro de
   `archiso-profile/airootfs/opt/crias-server/`. Também escreve um
   `.sync-manifest` com o commit git que gerou a ISO (para auditoria).

3. **(Opcional) Valide que o sync funcionou**:
   ```bash
   bash tests/iso-embedded-scripts-validate.sh
   ```
   Este teste confere que os 20 arquivos essenciais estão presentes, têm
   permissão executável, e que o `install.sh` embutido bate com o do repo.

4. **Construa a ISO**:
   ```bash
   sudo mkarchiso -v -w /tmp/archiso-tmp -o out/ archiso-profile/
   ```
   Ao final, o arquivo `crias-server-os-*.iso` estará em `out/`.

5. **Flash em pendrive** (BalenaEtcher, Rufus, ou `dd`):
   ```bash
   sudo dd if=out/crias-server-os-*.iso of=/dev/sdX bs=4M status=progress conv=fsync
   ```

### Boot na máquina alvo

1. Plug o pendrive e dê boot pela USB.
2. Ao cair no console do live USB, o `.automated_script.sh` abre sozinho
   no primeiro login do root.
3. Para entrar **apenas no shell do live** (sem rodar o instalador):
   - Defina `CRIAS_SKIP_AUTOSTART=1` no prompt do kernel, ou
   - Faça login com `CRIAS_SKIP_AUTOSTART=1` antes do Enter.

### Variáveis de ambiente do bootstrap

| Variável | Default | Descrição |
|----------|---------|-----------|
| `CRIAS_SKIP_AUTOSTART` | (vazio) | Se `1`, não roda o `.automated_script.sh` no login. |
| `CRIAS_REPO_REF` | `main` | Branch/tag do git para clonar no fallback (se ISO não tiver scripts embutidos). |
| `SKIP_VERIFY` | `0` | Se `1`, pula verificação GPG do commit no fallback. |
| `INSTALL_SH_SHA256` | (vazio) | Se setado, valida checksum do `install.sh` antes de rodar. |

## O que está (e não está) embutido na ISO

### Embutido (não precisa de internet no boot)

- **Instalador completo**: `install.sh`, `config.env`, `packages.lock`
- **Bibliotecas bash**: `shared/lib/*.sh` (common, downloads, hardware-profile, etc.)
- **Stack installers**: `minecraft/install.sh`, `terraria/install.sh`
- **Manager scripts**: `mc-manager.sh`, `tt-manager.sh`, `backup-cron.sh`, etc.
- **Systemd templates**: `minecraft.service`, `terraria.service`
- **Branding**: escudo e banner do Crias (usados em `print_header`)
- **Pacotes pacman**: Java 21, NetworkManager, Tailscale, curl, wget, htop,
  vim, git, etc. (lista completa em `archiso-profile/packages.x86_64`)

### Baixado sob demanda pelo `install.sh`

- **mrpack-install** (se `MINECRAFT_INSTALL_MODPACK=true`) — pinado em versão
  específica com checksum SHA256.
- **Mods QoL** (se `MINECRAFT_INSTALL_QOL_MODS=true`) — via Modrinth API.
- **Modpack Adrenaline** (se `MINECRAFT_MODPACK_SOURCE=adrenaline`) — via
  Modrinth.
- **Terraria dedicated server** — `TERRARIA_DOWNLOAD_URL` (oficial re-logic).
- **crias-agent** (se `INSTALL_AGENT=true`) — binário Go da GitHub release.

> **Nota sobre Tailscale**: Tailscale já vem pré-instalado na ISO (em
> `packages.x86_64`). O `install.sh` apenas ativa o daemon `tailscaled` se
> `INSTALL_TAILSCALE=true`. Se você estiver instalando em um host sem a ISO
> (Arch Linux limpo), o `install.sh` baixa o Tailscale via pacman com fallback
> para o repo oficial.

### Não embutido (e não baixado)

- `discord-agent/` source — apenas o binário pré-compilado é baixado.
- `discord-bot/` source — bot Python é deployado separadamente no Railway.
- `docs/`, `tests/`, `.github/` — não necessários em runtime.

## CI/CD

No GitHub Actions, o job `build-iso` (em `.github/workflows/ci.yml`) já executa
`sync-airootfs.sh` e `tests/iso-embedded-scripts-validate.sh` antes do
`mkarchiso`, garantindo que toda ISO publicada na release tenha o instalador
embutido e validado.

## Troubleshooting

### "Instalador não embutido na ISO — vou clonar do GitHub (fallback)"

Você está rodando uma ISO que foi construída sem rodar `sync-airootfs.sh`
antes do `mkarchiso`. O fallback via git clone ainda funciona se houver
internet, mas para gerar ISOs "prontas pra uso" execute o sync antes do build.

### ISO muito grande

A ISO típica fica em ~1.5-2GB. Se precisar reduzir:
- Comente pacotes opcionais em `packages.x86_64` (ex.: `memtest86+`, `edk2-shell`)
- Use `airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M' '-Xcompression-level' '19')`
  para compressão mais agressiva (mais lento para bootar)

### Boot falha em hardware antigo (BIOS legacy)

A ISO suporta `bios.syslinux` (legacy) + `uefi.grub` (UEFI). Se o hardware
é muito antigo e não tem UEFI, use o modo BIOS legacy. Se nem isso funciona,
verifique que o pendrive foi flasheado com `dd` (não Etcher, que às vezes
tem issues em BIOS antigo).

### Erro "archlinux-keyring" no install.sh

Rode `pacman -Sy archlinux-keyring && pacman -Su` antes do `install.sh`,
ou sete `INSTALL_TAILSCALE=false` se não precisa do Tailscale agora.
