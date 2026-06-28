# Crias-Server

<p align="center">
    <img src="assets/images/branding/EscudoCrias.png" alt="Escudo Crias" width="220" />
</p>

Instalador modular para servidor de jogos em Arch Linux, com escolha inicial entre Minecraft e Terraria, tuning automático por hardware, hardening systemd, controle remoto via bot Discord e CI/CD completo (build ISO + binário Go + bot Python).

## Principais recursos

- **Stack único por host**: Minecraft ou Terraria (systemd `Conflicts=` impede ambos rodando simultaneamente).
- **Tuning automático por hardware**: detecta RAM/CPU/disco e aplica tier LOW/MID/HIGH (override manual via `FORCE_HARDWARE_TIER`).
- **Hardening systemd**: `ProtectSystem=strict`, `NoNewPrivileges`, `CapabilityBoundingSet=`, `SystemCallFilter=@system-service` em todos os templates `.service`.
- **Supply chain seguro**: SHA256 obrigatório em downloads, `mrpack-install` pinado em versão específica, `packages.lock` com versões mínimas de pacotes pacman.
- **Backup com RCON save-lock** (Minecraft): `save-off` + `save-all` antes do `tar`, `save-on` depois.
- **Controle remoto via Discord** (opcional): agente Go (`crias-agent`) + bot Python (`discord-bot`) com slash commands `/mc start|stop|status|players|say|console|health`.
- **CI/CD**: workflow único `ci.yml` com 11 jobs paralelos (lint + test + build), release consolidada com ISO + binários Go + Docker bot + source archives + checksums + assinatura GPG opcional.
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
├── install.sh                  # Bootstrap principal
├── config.env                  # Configuração global (PT-BR comentado)
├── packages.lock               # Versões mínimas de pacotes pacman críticos
├── shared/lib/                 # Bibliotecas bash compartilhadas
│   ├── common.sh               #   log/warn/err, dry-run, is_virtualized, generate_token
│   ├── config-parser.sh        #   Parser de .env com escape de $()` e aspas
│   ├── downloads.sh            #   download_and_verify (SHA256 obrigatório, retry backoff)
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
├── archiso-profile/            # Perfil archiso para build de ISO bootável
├── tests/                      # 22 testes bash + 36 testes Python + helpers
└── .github/workflows/          # Workflow único: ci.yml (11 jobs paralelos + release)
```

## Tuning por hardware

O sistema detecta automaticamente RAM total, CPU cores e tipo de disco (HDD/SSD/NVME), e aplica um tier que afeta tanto parâmetros do jogo quanto limites de serviço systemd (`MemoryMax`).

| Tier | Perfil alvo | Comportamento típico |
|------|-------------|----------------------|
| LOW  | Máquinas limitadas (≤3 GB RAM ou ≤2 cores) | Menos players, distâncias menores, heap reduzido |
| MID  | Máquinas intermediárias (≤12 GB ou ≤6 cores) | Balanceado para estabilidade e desempenho |
| HIGH | Máquinas robustas (>12 GB e >6 cores) | Mais players, distâncias maiores, parâmetros agressivos |

**Override manual** em `config.env`:
```bash
FORCE_HARDWARE_TIER="HIGH"   # LOW, MID, HIGH ou vazio para auto
```

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

## Controle Remoto via Discord (opcional)

Quando `INSTALL_AGENT=true`, o `install.sh` instala:
1. **`crias-agent`** — binário Go que escuta em `localhost:8473` (hardening: `MemoryMax=32M`, `CPUQuota=10%`, `MemoryDenyWriteExecute=yes`)
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
   mcrcon say/list/save-*
```

### Slash Commands disponíveis no Discord

| Comando | Permissão | Descrição |
|---------|-----------|-----------|
| `/mc start` | Admin | Liga o servidor |
| `/mc stop` | Admin | Desliga graceful |
| `/mc restart` | Admin | Reinicia |
| `/mc status` | Todos | Online/offline, players, RAM, tier |
| `/mc players` | Todos | Lista quem está online |
| `/mc say <msg>` | Mod+ | Mensagem no chat do jogo via RCON |
| `/mc console` | Admin | Toggle stream de console no canal #console |
| `/mc health` | Admin | Health check (porta + RCON) |

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

Workflow único: [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — 11 jobs em paralelo + release consolidada.

### Jobs de lint + test (paralelos, rodam em todo push/PR)

| Job | Função | Runner |
|-----|--------|--------|
| `lint-shell` | Shellcheck (suprime falsos positivos SC1091/SC2034/SC2016) | ubuntu-22.04 |
| `lint-go` | `go vet` + `gofmt -l` check (após `go mod tidy` + proto) | ubuntu-22.04 |
| `lint-python` | `ruff check` + `ruff format --check` | ubuntu-22.04 |
| `test-shell` | Quick tests + contracts + static-audit + stack-installer | ubuntu-22.04 |
| `test-shell-arch` | `arch-smoke` + `arch-dry-install` (container Arch) | archlinux:base-devel |
| `test-go` | `go test -race` (após `go mod tidy` + proto) | ubuntu-22.04 |
| `test-python` | `pytest` em Python 3.11 e 3.12 (matrix) | ubuntu-22.04 |

### Jobs de build (paralelos, só em push to main ou tag `v*`)

| Job | Função | Runner |
|-----|--------|--------|
| `build-iso` | `mkarchiso` (ISO bootável) — depende de lint-shell + test-shell + test-shell-arch | archlinux:base-devel |
| `build-agent` | Build Go linux/amd64 + linux/arm64 (matrix) — depende de lint-go + test-go | ubuntu-22.04 |
| `build-bot` | Docker build smoke — depende de lint-python + test-python | ubuntu-22.04 |

### Job de release (consolida todos artefatos)

| Job | Função |
|-----|--------|
| `release` | Baixa todos os artefatos dos 3 builds e cria **uma release única** com tudo |

**Release consolidada** (em tag `v*.*.*` ou `workflow_dispatch` com `create_release=true`):
- `crias-server-*.iso` — ISO bootável
- `crias-server-full.zip` — repo completo
- `crias-server-slim.zip` — repo sem `archiso-profile/`, `docs/`, `.github/workflows/` (para quem já tem ISO)
- `crias-agent-linux-amd64` + `arm64` + `.sha256` — binários do agente Go
- `crias-bot-image.tar` — Docker image do bot
- `sha256sums.txt` — checksums de todos os artefatos
- `sha256sums.txt.sig` — assinatura GPG (se `GPG_PRIVATE_KEY` secret configurado)

## Testes

```bash
# Bateria completa (22 testes bash + 36 testes Python)
bash tests/run-all.sh

# Apenas bash rápido
bash tests/quick-script-tests.sh

# Testes que requerem ISO construída
ISO_PATH=/path/to/crias.iso bash tests/run-all.sh
```

## Documentação

- [docs/README.md](docs/README.md) — Índice central de toda a documentação
- [docs/tutorial.md](docs/tutorial.md) — Tutorial passo-a-passo de operação
- [docs/minecraft/README.md](docs/minecraft/README.md) — Stack Minecraft + mods
- [docs/terraria/README.md](docs/terraria/README.md) — Stack Terraria
- [docs/tailscale.md](docs/tailscale.md) — Conexão via Tailscale (VPN + Funnel)
- [docs/restore.md](docs/restore.md) — Restore de backups
- [docs/security.md](docs/security.md) — Firewall, logs, health checks, MAC
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — Histórico de mudanças por versão
- [ROADMAP.md](ROADMAP.md) — Status de implementação e próximos passos

## Atenção: desativação do stack oposto

Durante a instalação, se existir stack oposto no host, o instalador apenas **desativa** os serviços associados e remove o autoload de aliases — **não remove dados** em `/opt` nem exclui usuários. Essas operações destrutivas exigiriam comando opt-in separado com confirmação explícita.

## Licença

MIT — veja [LICENSE](LICENSE) (ou o cabeçalho dos arquivos).
