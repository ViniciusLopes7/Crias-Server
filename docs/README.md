# Documentação Crias-Server

Índice central de toda a documentação. Para visão geral de alto nível, veja o [README principal](../README.md).

## Visão Geral

| Documento | Descrição |
|-----------|-----------|
| [../README.md](../README.md) | Visão geral + quick start + controle remoto Discord |
| [../ROADMAP.md](../ROADMAP.md) | Status de implementação e próximos passos |
| [CHANGELOG.md](CHANGELOG.md) | Histórico de mudanças por versão |

## Tutorial

| Documento | Descrição |
|-----------|-----------|
| [tutorial.md](tutorial.md) | Fluxo único: instalar → operar → troubleshoot |
| [tailscale.md](tailscale.md) | Conexão via Tailscale (VPN + Funnel para crias-agent) |
| [hardware-tuning.md](hardware-tuning.md) | Tuning por hardware (tiers LOW/MID/HIGH, thresholds, recalibração) |
| [restore.md](restore.md) | Restore de backups (passo-a-passo Minecraft + Terraria) |
| [security.md](security.md) | Firewall, logs, health checks, hardening systemd, cleanup do stack oposto |

## Stack Minecraft

| Documento | Descrição |
|-----------|-----------|
| [minecraft/README.md](minecraft/README.md) | Componentes, comandos, aliases, RCON, troubleshooting |
| [minecraft/mods.md](minecraft/mods.md) | Guias dos mods QoL (Chunky, EssentialCommands, Universal Graves, TabTPS, StyledChat) |

## Stack Terraria

| Documento | Descrição |
|-----------|-----------|
| [terraria/README.md](terraria/README.md) | Componentes, comandos, aliases, troubleshooting |

## Controle Remoto Discord

| Documento | Descrição |
|-----------|-----------|
| [../discord-agent/README.md](../discord-agent/README.md) | Agente Go (gRPC ServerControl + EventBus, RCON, eventos, hardening) |
| [../discord-bot/README.md](../discord-bot/README.md) | Bot Python (discord.py 2.x, slash commands, Railway, Tailscale Funnel) |
| [../discord-agent/agent.example.yaml](../discord-agent/agent.example.yaml) | Template de config do agente |
| [../discord-bot/.env.example](../discord-bot/.env.example) | Template de env vars do bot |

## CI/CD

Workflow único: [../.github/workflows/ci.yml](../.github/workflows/ci.yml) — 11 jobs em paralelo + release consolidada.

### Lint + Test (paralelos, rodam em todo push/PR)

| Job | Função |
|-----|--------|
| `lint-shell` | Shellcheck (suprime falsos positivos SC1091/SC2034/SC2016) |
| `lint-go` | `go vet` + `gofmt -l` (após `go mod tidy` + proto) |
| `lint-python` | `ruff check` + `ruff format --check` |
| `test-shell` | Quick tests + contracts + static-audit + stack-installer |
| `test-shell-arch` | `arch-smoke` + `arch-dry-install` (Arch container) |
| `test-go` | `go test -race` (após `go mod tidy` + proto) |
| `test-python` | `pytest` em Python 3.11 e 3.12 (matrix) |

### Build (paralelos, só em push to main ou tag `v*`)

| Job | Função |
|-----|--------|
| `build-iso` | `mkarchiso` (ISO bootável) |
| `build-agent` | Build Go linux/amd64 + linux/arm64 (matrix) |
| `build-bot` | Docker build smoke |

### Release (consolida todos artefatos)

| Job | Função |
|-----|--------|
| `release` | Em tag `v*.*.*` ou `workflow_dispatch` com `create_release=true`: cria UMA release com ISO + binários Go + Docker bot + source archives + checksums + assinatura GPG opcional |

## Testes

```bash
# Bateria completa (22 testes bash + 36 testes Python)
bash tests/run-all.sh

# Apenas bash rápido
bash tests/quick-script-tests.sh

# Testes que requerem ISO construída
ISO_PATH=/path/to/crias.iso bash tests/run-all.sh
```

## Historico de documentação removida

Os seguintes documentos foram removidos na v1.0.0 por serem obsoletos ou redundantes:

- `docs/plano-arquitetura.md` — plano original executado; histórico preservado em `CHANGELOG.md`
- `docs/InstalacaoManual.md` — tutorial antigo para hardware específico (i3-6006U, 4GB RAM); tudo automatizado pelo `install.sh`
- `docs/Chunky.md`, `docs/EssentialCommands.md`, `docs/StyledChat.md` — consolidados em `minecraft/mods.md`
- `docs/shared/Compatibilidade.md` — dizia apenas "transição terminou"; informação óbvia
- `docs/shared/Cleanup.md` — consolidado em `security.md`
- `docs/shared/SecurityAndOps.md` — consolidado em `security.md`
- `docs/shared/HardwareTuning.md` — movido para `hardware-tuning.md`
- `docs/shared/Restore.md` — movido para `restore.md`
