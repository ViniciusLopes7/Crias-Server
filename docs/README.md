# Documentação Crias-Server

Este índice organiza os guias por tarefa. Comece pelo tutorial para instalar; consulte os guias específicos para configurar, operar e diagnosticar problemas. Para uma visão geral, veja o [README principal](../README.md).

## Primeiros passos

| Documento | Descrição |
|-----------|-----------|
| [../README.md](../README.md) | Visão geral + quick start + controle remoto Discord |
| [tutorial.md](tutorial.md) | Fluxo completo: instalar (bootstrap curl ou git clone) → operar → troubleshoot |
| [../CHANGELOG.md](../CHANGELOG.md) | Histórico de versões |
| [../ROADMAP.md](../ROADMAP.md) | Status de implementação e próximos passos |

## Como usar esta documentação

- **Primeira instalação ou atualização:** [tutorial](tutorial.md).
- **Servidor não inicia ou TUI ausente:** [TUI e recuperação](tui.md) e [ajustes de memória](hardware-tuning.md).
- **Importar modpack próprio:** [Minecraft e `.mrpack`](minecraft/modpacks.md).
- **Restaurar mundo:** [procedimento de backup e restauração](restore.md), começando pela verificação do arquivo.

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

O workflow [CI/CD](../.github/workflows/ci.yml) executa lint, testes por linguagem, validações em container Arch, launchers Java 21/25 e uma VM QEMU com Arch Linux e systemd. Jobs de build e publicação são condicionados ao evento. Uma execução verde **não equivale** à validação de todos os cenários de produção.

### Lint + Test (paralelos, rodam em todo push/PR)

| Job | Função |
|-----|--------|
| `lint-shell` | Shellcheck (suprime falsos positivos SC1091/SC2034/SC2016) |
| `lint-go` | `go vet` + `gofmt -l` (após `go mod tidy` + proto) |
| `lint-python` | `ruff check` + `ruff format --check` |
| `test-shell` | Quick tests + contracts + static-audit + stack-installer + mutation test |
| `test-shell-arch` | `arch-smoke` + `arch-dry-install` (container Arch, sem systemd como PID 1) |
| `test-go` | `go test -race` (após `go mod tidy` e geração de protobuf) |
| `test-python` | Testes Python com `pytest` |

### Integração real e QEMU

| Job | O que valida |
|---|---|
| `test-minecraft-jvm` | Launcher de produção em Java 21 e 25, com servidor de teste inofensivo. |
| `test-arch-vm` | Arch real em QEMU com systemd, serviços, download dos servidores, `.mrpack` e caminhos de falha. Os jogos Minecraft param na EULA. |

Detalhes, evidências e limites de cobertura: [validação QEMU](testing-qemu.md).

### Build (conforme evento do workflow)

| Job | Função |
|-----|--------|
| `build-agent` | Build Go linux/amd64 — depende de lint-go + test-go |
| `build-bot` | Docker build smoke — depende de lint-python + test-python |

### Release (consolida todos artefatos)

| Job | Função |
|-----|--------|
| `release` | Em tag `v*.*.*` ou `workflow_dispatch` com `create_release=true`: cria UMA release com binários Go + zip do bot + source archives + checksums SHA256 (sem ISO — o pipeline de ISO foi descontinuado) |

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

# Testes que requerem artefatos de release construídos (legado; sem ISO no pipeline atual)
ISO_PATH=/path/to/crias.iso bash tests/run-all.sh
```
