# Crias-Server

<p align="center">
    <img src="assets/images/branding/EscudoCrias.png" alt="Escudo Crias" width="180" />
</p>

<p align="center">
    <strong>Instalador modular para servidor de Minecraft e Terraria em Arch Linux.</strong><br>
    Tuning automático por hardware, hardening systemd, backup com RCON, controle remoto via Discord.
</p>

<p align="center">
    <a href="https://github.com/ViniciusLopes7/Crias-Server/releases"><img src="https://img.shields.io/github/v/release/ViniciusLopes7/Crias-Server?style=flat-square&color=blue" alt="Release"></a>
    <a href="https://github.com/ViniciusLopes7/Crias-Server/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ViniciusLopes7/Crias-Server/ci.yml?style=flat-square" alt="CI"></a>
    <a href="LICENSE"><img src="https://img.shields.io/github/license/ViniciusLopes7/Crias-Server?style=flat-square" alt="License"></a>
</p>

---

## O que é

Crias-Server é um instalador e gerenciador para servidor de jogos em Arch Linux. Você escolhe entre Minecraft ou Terraria, e ele cuida do resto: instala o servidor, configura tuning de hardware, hardening systemd, backup automático e controle remoto via Discord.

### Por que usar?

- **Sem Docker, sem overhead**: roda direto no Arch com systemd. Máximo de performance para o servidor de jogos.
- **Tuning automático**: detecta RAM, CPU e disco. Aplica LOW/MID/HIGH tier que ajusta heap, max-players, MemoryMax e políticas do host.
- **Hardening de verdade**: `ProtectSystem=strict`, `NoNewPrivileges`, `SystemCallFilter=@system-service`, `CapabilityBoundingSet=` em todos os serviços.
- **Backup inteligente**: RCON `save-off` + `save-all` antes do tar, `save-on` depois (com trap EXIT). Retenção por tier, compressão zstd, rsync remoto opcional.
- **TUI com gum**: menus interativos, busca fuzzy, mini-wiki, preview de MOTD colorido. Hub central (`crias-tui`) sem precisar lembrar comandos.
- **Controle remoto via Discord**: bot Python + agente Go com slash commands `/mc start|stop|status|players|say|console|health`.

## Instalação

### Pré-requisitos

- Arch Linux instalado ([ISO oficial](https://archlinux.org/download/) + `archinstall`)
- Acesso `sudo`
- Conexão com internet

### Passo a passo

```bash
# 1. Instale o Arch Linux (se ainda não tem)
#    Baixe a ISO oficial, boot, rode: archinstall
#    Crie usuário, timezone, disco, network → reboot

# 2. Baixe o Crias-Server (bootstrap com verificação SHA256)
curl -fsSL https://raw.githubusercontent.com/ViniciusLopes7/Crias-Server/main/crias-bootstrap.sh | sudo bash

# 3. Siga o TUI interativo (menus com gum)
#    Stack → opções globais → opções do jogo → resumo → confirmar

# 4. Pronto! Gerencie via hub TUI:
sudo crias-tui
```

### Alternativa (git clone)

```bash
git clone https://github.com/ViniciusLopes7/Crias-Server.git
cd Crias-Server
sudo ./install.sh
```

### Não-interativo (CI/automação)

```bash
sudo -E NON_INTERACTIVE=true ACCEPT_EULA=true SERVER_TYPE=minecraft ./install.sh
```

## Recursos

### Servidor de jogos

| Recurso | Minecraft | Terraria |
|---------|:---------:|:--------:|
| Start/stop/restart via systemd | ✅ | ✅ |
| Tuning automático (heap, max-players, view-distance) | ✅ | ✅ |
| Console interativo (RCON) | ✅ | — |
| Backup com save-lock | ✅ | ✅ |
| Restore | ✅ | ✅ |
| Server icon (URL → server-icon.png) | ✅ | — |
| MOTD personalizado (com preview) | ✅ | — |

### Minecraft específico

- **Loaders**: fabric, quilt, vanilla, forge, neoforge
- **Versão dinâmica**: busca do manifest oficial do loader (Mojang/Fabric/Quilt/NeoForge/Forge)
- **Modpacks**: top-10 Modrinth, busca por nome, vanilla, ou slug manual
- **Mods QoL**: Chunky, EssentialCommands, Universal Graves, TabTPS, StyledChat
- **tModLoader** (Terraria): catálogo curado (Calamity, Thorium, Magic Storage, Recipe Browser)

### Sistema

- **Tiers LOW/MID/HIGH**: detecção automática de RAM/CPU/disco com override manual
- **Hardening systemd**: todos os `.service` com `ProtectSystem=strict`, `NoNewPrivileges`, etc.
- **SSH**: usuário customizável (validação + bloqueio de reservados), `PermitRootLogin no`
- **Tailscale**: VPN mesh + Funnel para expor o crias-agent via HTTPS
- **Monitoramento**: `btop` (CPU/RAM), `ncdu` (disco), integrados ao `crias-tui` hub
- **Backup remoto**: rsync para `BACKUP_REMOTE_PATH` + notificação Discord via webhook

### Controle remoto Discord

- **crias-agent** (Go): gRPC em localhost:8473, hardening (`MemoryMax=128M`, `CPUQuota=10%`)
- **crias-bot** (Python): discord.py 2.x, slash commands, deploy via Dockerfile
- **Eventos**: server start/stop, player join/leave, health warnings → postados no canal `#controle`

## Estrutura do projeto

```
crias-server/
├── install.sh              # Instalador principal (TUI gum)
├── crias-bootstrap.sh      # Bootstrap: baixa release do GitHub + verifica SHA256
├── crias-tui.sh            # Hub TUI central (menu: servidor/monitor/backup/sistema)
├── config.env              # Configuração global (PT-BR comentado)
├── shared/lib/             # Bibliotecas bash compartilhadas
│   ├── common.sh           #   log, dry-run, mktemp_crias, prompts
│   ├── tui.sh              #   TUI: gum wrapper + fallback + motd_preview + tui_help
│   ├── manager-common.sh   #   Manager compartilhado (dispatch, show_help, monitor)
│   ├── backup-engine.sh    #   Backup com flock + retenção + rsync + webhook
│   └── ...                 #   mc-manifests, tmodloader, hardware-profile, etc.
├── minecraft/              # Stack Minecraft
├── terraria/               # Stack Terraria (espelho)
├── discord-agent/          # Agente Go (gRPC + RCON + eventos)
├── discord-bot/            # Bot Python (discord.py + slash commands)
└── tests/                  # Bateria de testes bash + mutation testing
```

## Configuração

Todas as opções em `config.env` (comentado em PT-BR). Principais:

| Variável | Default | Descrição |
|----------|---------|-----------|
| `SERVER_TYPE` | `""` | `minecraft` ou `terraria` (vazio = pergunta) |
| `FORCE_HARDWARE_TIER` | `""` | `LOW`/`MID`/`HIGH` ou vazio para auto |
| `MINECRAFT_LOADER` | `fabric` | `fabric`/`quilt`/`vanilla`/`forge`/`neoforge` |
| `MINECRAFT_VERSION` | `1.21.11` | Vazio = busca dinâmica do manifest |
| `MINECRAFT_MOTD` | `§6§l🏰...` | MOTD com códigos § (ver gerador em tutorial.md) |
| `MINECRAFT_SERVER_ICON_URL` | `""` | URL de PNG 64x64 para server-icon.png |
| `SSH_USER` | `crias` | Nome do usuário SSH (com validação) |
| `INSTALL_MONITOR_TOOLS` | `false` | Instala btop + ncdu no host |
| `BACKUP_REMOTE_PATH` | `""` | `user@host:/path/` para rsync remoto |
| `BACKUP_NOTIFY_WEBHOOK` | `""` | URL webhook Discord para notificações de backup |

## Testes

```bash
# Bateria completa
bash tests/run-all.sh

# Mutation testing (valida qualidade dos testes)
bash tests/mutation-test.sh

# Self-test das libs
bash shared/lib/tui.sh selftest
bash shared/lib/mc-manifests.sh selftest
```

## Documentação

| Documento | Descrição |
|-----------|-----------|
| [docs/tutorial.md](docs/tutorial.md) | Tutorial completo: instalar → operar → troubleshoot |
| [docs/hardware-tuning.md](docs/hardware-tuning.md) | Tiers LOW/MID/HIGH, thresholds, recalibração |
| [docs/security.md](docs/security.md) | Firewall, SSH, hardening, health checks |
| [docs/restore.md](docs/restore.md) | Restore de backups passo-a-passo |
| [docs/tui.md](docs/tui.md) | Como o TUI (gum) funciona + fallback |
| [docs/gui-feasibility.md](docs/gui-feasibility.md) | Estudo de viabilidade de GUI web (futuro) |
| [CHANGELOG.md](CHANGELOG.md) | Histórico de versões |
| [ROADMAP.md](ROADMAP.md) | Status e próximos passos |

## CI/CD

Workflow único `.github/workflows/ci.yml`:

- **Lint**: shellcheck, `go vet`, `gofmt -l`, `ruff check`
- **Test**: bash (33+ testes), Go (`-race`), Python (`pytest`), mutation testing
- **Build**: binário Go linux/amd64 + Docker smoke do bot
- **Release**: tag `v*.*.*` ou `workflow_dispatch` → GitHub release com binário + bot zip + source archives + checksums SHA256 + SLSA attestation

## Roadmap

- [ ] **GUI web** estilo CasaOS (dashboard com ícones, tier-gated) — [estudo](docs/gui-feasibility.md)
- [ ] **ISO customizada** (archiso com Crias-Server pré-instalado) — quando o projeto tiver maturidade
- [ ] **Bridge chat Discord ↔ Minecraft** (mensagens bidirecionais)
- [ ] **Métricas Prometheus** no agente
- [ ] **Agente Discord para Terraria** (tModLoader sem RCON nativo)

Veja [ROADMAP.md](ROADMAP.md) para o status completo.

## Comunidade

- **Issues**: [github.com/ViniciusLopes7/Crias-Server/issues](https://github.com/ViniciusLopes7/Crias-Server/issues)
- **Discussions**: [github.com/ViniciusLopes7/Crias-Server/discussions](https://github.com/ViniciusLopes7/Crias-Server/discussions)

## Licença

MIT — veja [LICENSE](LICENSE).
