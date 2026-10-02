# Crias-Server

<p align="center">
    <img src="assets/images/branding/EscudoCrias.png" alt="Escudo Crias" width="220" />
</p>

Instalador modular para servidor de jogos em Arch Linux, com escolha inicial entre Minecraft e Terraria, tuning automático por hardware, hardening systemd, controle remoto via bot Discord e CI/CD completo (binário Go + bot Python).

>
> **v1.2.0**: ISO agora inclui **OpenSSH** e **`gum`** (TUI). O instalador oferece **seleção dinâmica de versão do Minecraft** e **seletor de modpacks** (top-10 Modrinth / busca / vanilla / slug manual) com sugestão de versão compatível. Loader `paper` removido. Veja o [CHANGELOG.md](CHANGELOG.md) para detalhes.

## Principais recursos

- **Stack único por host**: Minecraft ou Terraria (systemd `Conflicts=` impede ambos rodando simultaneamente).
- **TUI com `gum`** (v1.2.0): menus, busca fuzzy e prompts interativos. Fallback automático para `read` se `gum` ausente (CI/Arch limpo).
- **Versão do Minecraft dinâmica** (v1.2.0): busca do manifest oficial do loader (Mojang/Fabric/Quilt/NeoForge/Forge); seleção fuzzy; snapshots marcados visualmente.
- **Seletor de modpacks Modrinth** (v1.2.0): top-10 por downloads, busca por nome, vanilla, ou slug manual. Compatibilidade validada server-side; sugestão de versão MC mais próxima se incompatível.
- **OpenSSH** (v1.2.0): `openssh` pré-instalado na ISO; o `install.sh` pergunta se habilita SSH no host (cria usuário `crias` com sudo, `PermitRootLogin no`).
- **Tuning automático por hardware**: detecta RAM/CPU/disco e aplica tier LOW/MID/HIGH (override manual via `FORCE_HARDWARE_TIER`).
- **Hardening systemd**: `ProtectSystem=strict`, `NoNewPrivileges`, `CapabilityBoundingSet=`, `SystemCallFilter=@system-service` em todos os templates `.service`.
- **Backup com RCON save-lock** (Minecraft): `save-off` + `save-all` antes do `tar`, `save-on` depois (com trap EXIT para garantir reativação mesmo se o backup for morto).
- **Controle remoto via Discord** (opcional): agente Go (`crias-agent`) + bot Python (`discord-bot`) com slash commands `/mc start|stop|status|players|say|console|health`.
- **CI/CD**: workflow único `ci.yml` com 12 jobs paralelos (lint + test + build + release), release consolidada com ISO + binários Go + Docker bot + source archives + checksums SHA256.
- **Modo não-interativo e DRY_RUN** para testes em CI.

## Quick Start

### Instalação interativa (recomendado)

```bash
chmod +x install.sh
sudo ./install.sh
```

O instalador pergunta:
1. Qual stack instalar (Minecraft ou Terraria)
2. Revisar opções globais (Tailscale, tuning de sistema, cleanup do stack oposto)
3. Parâmetros específicos do jogo (porta, versão, modpack, etc.)
4. Se quer instalar o agente de controle remoto (`crias-agent`)

### Instalação não-interativa (CI/automação)

```bash
sudo -E NON_INTERACTIVE=true \
        ACCEPT_EULA=true \
        SERVER_TYPE=minecraft \
        INSTALL_AGENT=true \
        ./install.sh
```

### Validação em DRY_RUN (sem alterar o host)

```bash
sudo -E NON_INTERACTIVE=true DRY_RUN=true SERVER_TYPE=terraria ./install.sh
```

Flags importantes em `config.env`:
- `NON_INTERACTIVE=true` — desativa prompts (exige `SERVER_TYPE` definido).
- `DRY_RUN=true` — evita operações destrutivas (pacman/useradd/systemd/cleanup).
- `ACCEPT_EULA=true` — necessário para Minecraft em modo não-interativo.
- `INSTALL_AGENT=true` — instala o `crias-agent` (controle remoto via Discord).

## Estrutura do projeto

```
.
├── install.sh                  # Bootstrap principal (TUI gum + fallback read)
├── config.env                  # Configuração global (PT-BR comentado)
├── shared/lib/                 # Bibliotecas bash compartilhadas
│   ├── common.sh               #   log/warn/err, dry-run, is_virtualized, generate_token
│   ├── config-parser.sh        #   Parser de .env com escape de $()` e aspas
│   ├── downloads.sh            #   download_file (retry backoff)
│   ├── tui.sh                  #   TUI: gum wrapper com fallback read (v1.2.0)
│   ├── mc-manifests.sh         #   Mojang/Fabric/Quilt/NeoForge/Forge + Modrinth API (v1.2.0)
│   ├── hardware-profile.sh     #   Detecção de RAM/CPU/disco + tier
│   ├── system-tuning.sh        #   zram, sysctl, scheduler, cpupower
│   ├── stack-installer.sh      #   Framework de hooks para installers (DRY)
│   ├── backup-engine.sh        #   Engine de backup com flock + retenção
│   ├── setup-cron.sh           #   Timer systemd parametrizado
│   ├── minecraft-tuning.sh     #   Tuning específico Minecraft
│   └── terraria-tuning.sh      #   Tuning específico Terraria
├── minecraft/                  # Stack Minecraft
│   ├── install.sh              #   Installer (usa stack-installer.sh)
│   ├── start-server.sh         #   Launcher runtime (JAVA_OPTS como array)
│   ├── mc-manager.sh           #   CLI de gerenciamento
│   ├── backup-cron.sh          #   Backup com RCON save-lock
│   ├── setup-cron.sh           #   Wrapper para timer systemd
│   └── minecraft.service       #   Template systemd (envsubst + hardening)
├── terraria/                   # Stack Terraria (estrutura espelho do Minecraft)
├── discord-agent/              # Agente Go (gRPC + RCON + eventos)
├── discord-bot/                # Bot Python (discord.py 2.x + slash commands)
├── tests/                      # Bateria de testes bash + Python + Go (ver tests/run-all.sh)
│   ├── fixtures/               #   JSON fixtures para testes de manifest (v1.2.0)
│   ├── tui-fallback-test.sh    #   Teste do caminho fallback do TUI (v1.2.0)
│   └── mc-manifests-test.sh    #   Teste de parsing + sugestão de versão (v1.2.0)
├── docs/                       # Documentação
├── CHANGELOG.md                # Histórico de versões (v1.3.0+)
└── .github/workflows/          # Workflow único: ci.yml (12 jobs paralelos + release)
```

## Tuning por hardware

O sistema detecta automaticamente RAM total, CPU cores e tipo de disco (HDD/SSD/NVME), e aplica um tier **LOW / MID / HIGH** que afeta parâmetros do jogo, limites systemd (`MemoryMax`) e políticas de host (zram, scheduler, cpupower). Override manual via `FORCE_HARDWARE_TIER` em `config.env`. Veja a [tabela completa de tiers + thresholds + recalibração](docs/hardware-tuning.md).

**Recalibração após mudança de hardware** (sem reinstalar):
```bash
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware
sudo /opt/minecraft-server/mc-manager.sh reconfigure-hardware HIGH  # forçar tier
```

## Backup

Cada stack tem script de backup imediato + setup de timer systemd:

```bash
# Backup manual agora
sudo /opt/minecraft-server/mc-manager.sh backup
sudo /opt/terraria-server/tt-manager.sh backup

# Configurar timer systemd (pergunta frequência: diário, 2x/dia, 4h, semanal)
sudo /opt/minecraft-server/setup-cron.sh
sudo /opt/terraria-server/setup-cron.sh
```

- Retenção dinâmica baseada no tier (LOW=5 dias, MID=7, HIGH=10).
- Compressão zstd com ionice (baixa prioridade de I/O).
- Lock via `flock` (previne backups concorrentes).
- Minecraft com RCON: `save-off` + `save-all` antes, `save-on` depois.

Restore: veja [docs/restore.md](docs/restore.md).

## TUI e seleção dinâmica (v1.2.0)

O instalador interativo usa **`gum`** (Charm) para menus, busca fuzzy e prompts. A seleção de **versão do Minecraft** é dinâmica (buscada do manifest do loader), e o **seletor de modpacks** oferece top-10 do Modrinth, busca por nome, vanilla, ou slug manual — com sugestão de versão compatível.

```bash
sudo ./install.sh
# 1. Stack (Minecraft/Terraria) — menu TUI
# 2. Loader (fabric/quilt/vanilla/forge/neoforge) — menu TUI
# 3. Versão MC — busca fuzzy no manifest do loader
# 4. Modpack — top-10 / busca / vanilla / slug
# 5. Versão do modpack — filtrada por compatibilidade
# 6. Opções globais (Tailscale, tuning, cleanup, SSH) — checklist TUI
# 7. Opções específicas (porta, MOTD, online-mode, QoL)
```

Sem `gum` (Arch limpo sem ISO), o instalador cai automaticamente para prompts `read` clássicos. Veja [docs/tui.md](docs/tui.md) e [docs/minecraft/modpacks.md](docs/minecraft/modpacks.md).

## SSH (v1.2.0)

A ISO inclui `openssh` (disponível, mas `sshd` **não** sobe sozinho no live ISO). O `install.sh` pergunta se você quer habilitar SSH no host instalado:

- Se **sim**: instala `openssh`, habilita `sshd.service`, cria o usuário `crias` com `sudo` (senha pedida), e configura `PermitRootLogin no` (hardening).
- Se **não** (default): nada é configurado.

```bash
# Forçar via config.env:
INSTALL_SSH=true sudo ./install.sh

# Ou variável de ambiente:
sudo -E INSTALL_SSH=true SERVER_TYPE=minecraft NON_INTERACTIVE=true ACCEPT_EULA=true ./install.sh
```

No live ISO, para iniciar `sshd` manualmente (sem instalar): `systemctl start sshd`. Veja [docs/security.md](docs/security.md).

## Controle Remoto via Discord (opcional)

Quando `INSTALL_AGENT=true`, o `install.sh` instala:
1. **`crias-agent`** — binário Go que escuta em `localhost:8473` (hardening: `MemoryMax=128M`, `CPUQuota=10%`, `MemoryDenyWriteExecute=yes`)
2. **`crias-bot`** — bot Python (discord.py 2.x) para deploy no Railway

```
┌──────────────────────┐
│   Discord (Railway)  │  discord.py + slash commands
└──────────┬───────────┘
           │ gRPC over HTTPS (Tailscale Funnel)
           ▼
┌──────────────────────┐
│  crias-agent (Go)    │  localhost:8473 no servidor
└──────────┬───────────┘
           │ Delegação (subprocess)
           ▼
   sudo systemctl start/stop/restart minecraft
   sudo -u minecraft mc-manager.sh backup
   gorcon (github.com/gorcon/rcon) say/list/save-*
```

### Slash Commands disponíveis no Discord

O bot oferece `/mc start | stop | restart | status | players | say | console | health` com permissões por role (Admin/Mod+/Todos). Veja a [tabela completa de comandos + permissões](discord-bot/README.md) no README do bot.

Veja:
- [discord-agent/README.md](discord-agent/README.md) — Agente Go (gRPC, RCON, eventos)
- [discord-bot/README.md](discord-bot/README.md) — Bot Python (discord.py, slash commands)

### Tailscale Funnel

Após instalar Tailscale no host:
```bash
sudo tailscale up
sudo tailscale funnel 8473   # expõe https://<host>.<tailnet>.ts.net
```

O bot Discord conecta neste endpoint HTTPS sem precisar estar na VPN.

## CI/CD

Workflow único: [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — 12 jobs em paralelo + release consolidada.

### Jobs de lint + test (paralelos, rodam em todo push/PR)

| Job | Função | Runner |
|-----|--------|--------|
| `lint-shell` | Shellcheck (suprime falsos positivos SC1091/SC2034/SC2016) | ubuntu-22.04 |
| `lint-go` | `go vet` + `gofmt -l` check (após `go mod tidy` + proto) | ubuntu-22.04 |
| `lint-python` | `ruff check` + `ruff format --check` | ubuntu-22.04 |
| `test-shell` | Quick tests + contracts + static-audit + stack-installer | ubuntu-22.04 |
| `test-shell-arch` | `arch-smoke` + `arch-dry-install` (container Arch) | archlinux:base-devel |
| `test-go` | `go test -race` (após `go mod tidy` + proto) | ubuntu-22.04 |
| `test-python` | `pytest` em Python 3.12 | ubuntu-22.04 |

### Jobs de build (paralelos, só em push to main ou tag `v*`)

| Job | Função | Runner |
|-----|--------|--------|
| `test-iso-qemu` | Boot real da ISO no QEMU (BIOS + UEFI) — depende de build-iso | ubuntu-22.04 |
| `build-agent` | Build Go linux/amd64 — depende de lint-go + test-go | ubuntu-22.04 |
| `build-bot` | Docker build smoke — depende de lint-python + test-python | ubuntu-22.04 |

### Job de release (consolida todos artefatos)

| Job | Função |
|-----|--------|
| `release` | Baixa todos os artefatos dos 3 builds + valida que ISO passou no QEMU boot test, e cria **uma release única** com tudo |

**Release consolidada** (em tag `v*.*.*` ou `workflow_dispatch` com `create_release=true`):
- `crias-server-full.zip` — repo completo
- `crias-agent-linux-amd64` + `.sha256` — binário do agente Go (x86_64 only; a ISO é x86_64)
- `crias-bot.zip` — Source do bot + Dockerfile (usuário faz `docker build` local)
- `sha256sums.txt` — checksums de todos os artefatos

## Testes

```bash
# Bateria completa de testes bash + Python + Go (ver tests/run-all.sh para o total atual)
bash tests/run-all.sh

# Apenas bash rápido (incl. tui-fallback-test e mc-manifests-test)
bash tests/quick-script-tests.sh

# Self-test das libs novas (sem rede):
bash shared/lib/tui.sh selftest
bash shared/lib/mc-manifests.sh selftest

# Testes que requerem ISO construída
```

## Documentação

- [docs/README.md](docs/README.md) — Índice central de toda a documentação
- [CHANGELOG.md](CHANGELOG.md) — Histórico de versões (v1.3.0+)
- [docs/tutorial.md](docs/tutorial.md) — Tutorial passo-a-passo de operação
- [docs/tui.md](docs/tui.md) — Como o TUI (gum) funciona + fallback (v1.2.0)
- [docs/minecraft/README.md](docs/minecraft/README.md) — Stack Minecraft + mods
- [docs/minecraft/modpacks.md](docs/minecraft/modpacks.md) — Seletor de modpacks dinâmico (v1.2.0)
- [docs/terraria/README.md](docs/terraria/README.md) — Stack Terraria
- [docs/Tailscale.md](docs/Tailscale.md) — Conexão via Tailscale (VPN + Funnel)
- [docs/restore.md](docs/restore.md) — Restore de backups
- [docs/security.md](docs/security.md) — Firewall, SSH, logs, health checks, MAC
- [ROADMAP.md](ROADMAP.md) — Status de implementação e próximos passos

## Atenção: desativação do stack oposto

Durante a instalação, se existir stack oposto no host, o instalador apenas **desativa** os serviços associados e remove o autoload de aliases — **não remove dados** em `/opt` nem exclui usuários. Essas operações destrutivas exigiriam comando opt-in separado com confirmação explícita.

## Licença

MIT — veja [LICENSE](LICENSE) (ou o cabeçalho dos arquivos).
