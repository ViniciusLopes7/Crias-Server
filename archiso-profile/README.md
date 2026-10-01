# Gerador de ISO (Archiso) para o Crias-Server

A ISO gerada pelo Crias-Server é um **archiso padrão + pacotes pré-instalados +
bootstrap mínimo**. Ao dar boot, o root auto-loga no tty1 (padrão archiso
upstream) e o usuário decide o que fazer: rodar `archinstall` para instalar o
Arch no disco, depois rodar `crias-bootstrap` para baixar e extrair o
instalador do Crias-Server a partir da release do GitHub.

> **v1.3.0 (F1)**: Removido o auto-start quebrado (`.bash_profile` +
> `.automated_script.sh` + repo embutido em `/opt/crias-server/`). Adicionado
> drop-in de autologin do root no tty1 (padrão archiso upstream) e bootstrap
> mínimo que baixa a release com verificação SHA256. O bug de login (ISO
> inutilizável — root travado + sem autologin) está corrigido.

## Como a ISO funciona

```
┌─────────────────────────────────────────────────────────────────────┐
│  Boot do live USB                                                   │
│    └─> getty@tty1.service.d/autologin.conf → root autologin no tty1 │
│        └─> shell de root (NENHUM script auto-starta)                │
│                                                                     │
│  Usuário decide o fluxo:                                            │
│    1. archinstall          (instala Arch no disco em /mnt)          │
│    2. crias-bootstrap      (baixa release + verifica SHA256 +        │
│                             extrai em /mnt/opt/crias-server/)        │
│    3. reboot                                                         │
│    4. login com usuário criado no archinstall                        │
│    5. sudo /opt/crias-server/install.sh   (roda o instalador)        │
└─────────────────────────────────────────────────────────────────────┘
```

O bootstrap (`/usr/local/bin/crias-bootstrap` na ISO) é o único arquivo do
repo embutido. Ele consulta `api.github.com/repos/.../releases/latest`,
baixa `crias-server-slim.zip` e `sha256sums.txt`, verifica o SHA256 do zip
contra o checksum, extrai em `/mnt/opt/crias-server/` (ou `/opt/crias-server/`
se já no host instalado) e — no caso do host instalado — roda `install.sh`
direto. No caso da live ISO (pós-`archinstall`, mirando `/mnt`), o bootstrap
apenas extrai e imprime as próximas instruções (reboot + `install.sh`),
porque `install.sh` rodado em chroot teria problemas com `systemctl start`.

## Por que não embute mais nada

O repo embutido em `/opt/crias-server/` (20 arquivos) era inútil depois do
reboot: `archinstall` cria rootfs limpo, `/opt/crias-server/` não sobrevive.
O bootstrap resolve isso baixando a release correta do GitHub com checksum
(versionada, rastreável, íntegra). ISO fica menor (~5KB de Crias-Server vs.
~50 arquivos antes). Fallback offline: `git clone` do `main` (sem checksum).

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

2. **Sincronize o bootstrap do repo para dentro do airootfs**:
   ```bash
   # A partir da raiz do repo Crias-Server
   bash archiso-profile/sync-airootfs.sh
   ```
   Este passo copia `crias-bootstrap.sh` (repo root) para
   `archiso-profile/airootfs/usr/local/bin/crias-bootstrap` (executável) e
   escreve um manifesto `.version` com o commit git + SHA256 do bootstrap.

3. **(Opcional) Valide que o sync funcionou**:
   ```bash
   bash tests/iso-embedded-scripts-validate.sh
   ```
   Este teste confere que o bootstrap está presente, executável, bate com a
   fonte do repo, que o drop-in de autologin existe e referencia
   `--autologin root`, e que nenhum arquivo legacy (`.bash_profile`,
   `.automated_script.sh`, `customize_airootfs.sh`) está presente.

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
2. Root auto-loga no tty1 (sem digitar senha — drop-in de autologin).
3. Rode `archinstall` para instalar o Arch no disco (cria usuário, data, fuso,
   hostname, bootloader).
4. Rode `crias-bootstrap` para baixar/extrair o Crias-Server em `/mnt/opt/`.
5. `reboot`, faça login com o usuário criado no passo 3.
6. Rode `sudo /opt/crias-server/install.sh` para configurar o servidor.

Para entrar **apenas no shell do live** (sem rodar nada): não execute nenhum
comando. O autologin dá o shell; o que rodar a partir dele é opt-in.

## Variáveis de ambiente do bootstrap

| Variável | Default | Descrição |
|----------|---------|-----------|
| `CRIAS_REPO` | `ViniciusLopes7/Crias-Server` | Repo do GitHub a consultar. |
| `CRIAS_RELEASE_TAG` | (vazio = latest) | Tag específica da release (ex.: `v1.3.0`). |
| `CRIAS_ASSET_ZIP` | `crias-server-slim.zip` | Nome do asset zip na release. |
| `CRIAS_TARGET` | (auto) | `/mnt` se Arch montado; senão `/`. Override manual. |
| `GITHUB_TOKEN` | (vazio) | Auth opcional para evitar rate-limit da API. |

## O que está (e não está) embutido na ISO

### Embutido (não precisa de internet no boot)

- **Bootstrap**: `crias-bootstrap` (~5KB) em `/usr/local/bin/`
- **Pacotes pacman**: Java 21, NetworkManager, Tailscale, OpenSSH, `gum` (TUI),
  curl, wget, unzip, jq, git, htop, vim, etc. (lista completa em
  `archiso-profile/packages.x86_64`)
- **Drop-in de autologin**: `getty@tty1.service.d/autologin.conf` (root no tty1)

### Baixado pelo bootstrap (precisa de internet ao rodar `crias-bootstrap`)

- **`crias-server-slim.zip`** da latest release do GitHub (repo sem
  `archiso-profile/`, `docs/`, `.github/workflows/` — menor).
- **`sha256sums.txt`** da mesma release (para verificação de integridade).

### Baixado sob demanda pelo `install.sh`

- **mrpack-install** (se `MINECRAFT_INSTALL_MODPACK=true`)
- **Mods QoL** (se `MINECRAFT_INSTALL_QOL_MODS=true`) via Modrinth API
- **Modpack Adrenaline** (se `MINECRAFT_MODPACK_SOURCE=adrenaline`) via Modrinth
- **Terraria dedicated server** — `TERRARIA_DOWNLOAD_URL` (oficial re-logic)
- **crias-agent** (se `INSTALL_AGENT=true`) — binário Go da GitHub release

### Não embutido (e não baixado)

- `discord-agent/` source — apenas o binário pré-compilado é baixado.
- `discord-bot/` source — bot Python é deployado separadamente no Railway.
- `docs/`, `tests/`, `.github/` — não necessários em runtime.

## CI/CD

No GitHub Actions, o job `build-iso` (em `.github/workflows/ci.yml`) executa
`sync-airootfs.sh` e `tests/iso-embedded-scripts-validate.sh` antes do
`mkarchiso`, garantindo que toda ISO publicada na release tenha o bootstrap
embutido e validado.

## Troubleshooting

### "Asset 'crias-server-slim.zip' não encontrado na release"

A latest release do GitHub ainda não foi publicada (ou o asset `slim.zip`
não está na release). Verifique
`https://github.com/ViniciusLopes7/Crias-Server/releases`. Fallback:
```bash
git clone https://github.com/ViniciusLopes7/Crias-Server
cd Crias-Server
sudo ./install.sh
```

### "SHA256 mismatch! ... Abortando"

O zip baixado não bate com o checksum em `sha256sums.txt`. Pode ser
corrupção no download ou comprometimento. Não rode o `install.sh` de um
zip com checksum falho. Tente novamente; se persistir, use `git clone`
e audite o código manualmente antes de rodar.

### ISO muito grande

A ISO típica fica em ~1.5-2GB (a maior parte é Java 21 + linux-firmware).
Se precisar reduzir:
- Comente pacotes opcionais em `packages.x86_64` (ex.: `memtest86+`, `edk2-shell`)
- Use `airootfs_image_tool_options=('-comp' 'zstd' '-b' '1M' '-Xcompression-level' '19')`
  para compressão mais agressiva (mais lento para bootar)

### Boot falha em hardware antigo (BIOS legacy)

A ISO suporta `bios.syslinux` (legacy) + `uefi.grub` (UEFI). Se o hardware
é muito antigo e não tem UEFI, use o modo BIOS legacy. Se nem isso funciona,
verifique que o pendrive foi flasheado com `dd` (não Etcher, que às vezes
tem issues em BIOS antigo).

### "Root não consegue logar no tty2+"

Isso é **esperado**. O drop-in de autologin só bypassa a senha no tty1.
Nos demais ttys, root está travado no `/etc/shadow` (hardening preservado).
Para login em outros ttys, use o usuário criado no `archinstall`.
