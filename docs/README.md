# Documentação Crias-Server

Índice central de toda a documentação. Para visão geral de alto nível, veja o [README principal](../README.md).

## Primeiros passos

| Documento | Descrição |
|-----------|-----------|
| [../README.md](../README.md) | Visão geral + quick start + controle remoto Discord |
| [tutorial.md](tutorial.md) | Fluxo completo: instalar (ISO ou git clone) → operar → troubleshoot |
| [../archiso-profile/README.md](../archiso-profile/README.md) | Como a ISO funciona (bootstrap, autologin, build) |
| [../CHANGELOG.md](../CHANGELOG.md) | Histórico de versões |
| [../ROADMAP.md](../ROADMAP.md) | Status de implementação e próximos passos |

## Administração

| Documento | Descrição |
|-----------|-----------|
| [security.md](security.md) | Firewall, SSH, logs, health checks, hardening systemd, cleanup do stack oposto |
| [hardware-tuning.md](hardware-tuning.md) | Tuning por hardware (tiers LOW/MID/HIGH, thresholds, recalibração) |
| [restore.md](restore.md) | Restore de backups (passo-a-passo Minecraft + Terraria) |
| [Tailscale.md](Tailscale.md) | Conexão via Tailscale (VPN + Funnel para crias-agent) |
| [tui.md](tui.md) | TUI (gum) — como funciona, fallback, atalhos, mini-wiki |
| [gui-feasibility.md](gui-feasibility.md) | Estudo de viabilidade de GUI web (CasaOS-style, tier-gated) |

## Stack Minecraft

| Documento | Descrição |
|-----------|-----------|
| [minecraft/README.md](minecraft/README.md) | Componentes, comandos, aliases, RCON, troubleshooting |
| [minecraft/modpacks.md](minecraft/modpacks.md) | Seletor de modpacks dinâmico (top-10 Modrinth, busca, compatibilidade) |
| [minecraft/mods.md](minecraft/mods.md) | Guias dos mods QoL (Chunky, EssentialCommands, Universal Graves, TabTPS, StyledChat) |

## Stack Terraria

| Documento | Descrição |
|-----------|-----------|
| [terraria/README.md](terraria/README.md) | Componentes, comandos, aliases, troubleshooting |
| [tmodloader.md](tmodloader.md) | tModLoader (Terraria com mods) — instalação, catálogo, SteamCMD |

## Controle remoto Discord

| Documento | Descrição |
|-----------|-----------|
| [../discord-agent/README.md](../discord-agent/README.md) | Agente Go (gRPC ServerControl + EventBus, RCON, eventos, hardening) |
| [../discord-bot/README.md](../discord-bot/README.md) | Bot Python (discord.py 2.x, slash commands, Dockerfile, Tailscale Funnel) |
| [../discord-agent/agent.example.yaml](../discord-agent/agent.example.yaml) | Template de config do agente |
| [../discord-bot/.env.example](../discord-bot/.env.example) | Template de env vars do bot |

## CI/CD

Workflow único: [../.github/workflows/ci.yml](../.github/workflows/ci.yml) — 12 jobs em paralelo + release consolidada.

### Lint + Test (paralelos, rodam em todo push/PR)

| Job | Função |
|-----|--------|
| `lint-shell` | Shellcheck (suprime falsos positivos SC1091/SC2034/SC2016) |
| `lint-go` | `go vet` + `gofmt -l` (após `go mod tidy` + proto) |
| `lint-python` | `ruff check` + `ruff format --check` |
| `test-shell` | Quick tests + contracts + static-audit + stack-installer + mutation test |
| `test-shell-arch` | `arch-smoke` + `arch-dry-install` (Arch container) |
| `test-go` | `go test -race` (após `go mod tidy` + proto) |
| `test-python` | `pytest` em Python 3.12 |

### Build (paralelos, só em push to main ou tag `v*`)

| Job | Função |
|-----|--------|
| `build-iso` | `mkarchiso` (ISO bootável) |
| `test-iso-qemu` | Boot real da ISO no QEMU (BIOS + UEFI) — depende de build-iso |
| `build-agent` | Build Go linux/amd64 — depende de lint-go + test-go |
| `build-bot` | Docker build smoke — depende de lint-python + test-python |

### Release (consolida todos artefatos)

| Job | Função |
|-----|--------|
| `release` | Em tag `v*.*.*` ou `workflow_dispatch` com `create_release=true`: cria UMA release com ISO + binários Go + Docker bot + source archives + checksums SHA256 |

## Testes

```bash
# Bateria completa de testes bash + Python + Go (ver tests/run-all.sh para o total atual)
bash tests/run-all.sh

# Apenas bash rápido
bash tests/quick-script-tests.sh

# Mutation testing (valida qualidade dos testes)
bash tests/mutation-test.sh

# Self-test das libs (sem rede):
bash shared/lib/tui.sh selftest
bash shared/lib/mc-manifests.sh selftest

# Testes que requerem ISO construída
ISO_PATH=/path/to/crias.iso bash tests/run-all.sh
```
