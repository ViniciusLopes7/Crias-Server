# ROADMAP — Crias-Server

> Status de implementação e próximos passos.
> Última atualização: 2026-08-26.

## ✅ Implementado (v1.2.1)

### Branch `main` (única, monorepo)

| Componente | Status | Detalhes |
|------------|--------|----------|
| **tModLoader (Terraria com mods)** | ✅ (v1.2.1) | `shared/lib/tmodloader.sh` — GitHub Releases dinâmico, catálogo curado (Calamity, Thorium, etc.), SteamCMD, `Mods/enabled.json`. Substitui vanilla quando `TERRARIA_USE_TMODLOADER=true`. |
| **OpenSSH na ISO + host** | ✅ (v1.2.0) | `openssh` em `packages.x86_64`; `install.sh` pergunta se habilita SSH no host → cria usuário `crias` com sudo, `PermitRootLogin no` |
| **TUI (gum)** | ✅ (v1.2.0) | `shared/lib/tui.sh` — wrapper `gum` com fallback `read` automático; `gum` pré-instalado na ISO |
| **Versão MC dinâmica** | ✅ (v1.2.0) | `shared/lib/mc-manifests.sh` — busca manifests Mojang/Fabric/Quilt/NeoForge/Forge; seleção fuzzy; snapshots marcados |
| **Seletor de modpacks Modrinth** | ✅ (v1.2.0) | Top-10 / busca / vanilla / slug manual; compatibilidade server-side; sugestão de MC mais próxima |
| **Loaders** | ✅ (v1.2.0) | `fabric | quilt | vanilla | forge | neoforge` — `paper` **removido** |
| **Refactoring shell** | ✅ | 3 novas libs compartilhadas (`stack-installer.sh`, `backup-engine.sh`, `setup-cron.sh`) + `tui.sh` + `mc-manifests.sh` |
| **Hardening systemd** | ✅ | `envsubst` em templates `.service`, `CapabilityBoundingSet=`, `SystemCallFilter=@system-service`, etc. |
| **Supply chain** | ⚠️ | SHA256 dos artefatos de release gerado no CI; install.sh não verifica checksums em runtime |
| **Tuning por hardware** | ✅ | Detecção RAM/CPU/disco → tier LOW/MID/HIGH; skip automático em container/VPS |
| **Backup com RCON save-lock** | ✅ | Engine unificado com hooks pre/post; `save-off`+`save-all` antes, `save-on` depois; trap EXIT |
| **Agente Go** (`discord-agent/`) | ✅ | gRPC `ServerControl` (7 RPCs) + `EventBus`, PlayerMonitor, HealthMonitor, AutoShutdown |
| **Bot Discord** (`discord-bot/`) | ✅ | discord.py 2.x, slash commands `/mc start|stop|restart|status|players|say|console|health` |
| **Eventos push** | ✅ | `ServerStarted`/`Stopped`, `PlayerJoined`/`Left`, `HealthWarning` → bot posta em `#controle` |
| **Streaming console** | ✅ | `StreamConsole` RPC (journalctl -f) → bot posta em `#console` |
| **CI/CD** | ✅ | Workflow único `ci.yml` com 12 jobs paralelos + release unificado |
| **Testes** | ✅ | 24 testes bash (incl. 2 novos: `tui-fallback-test`, `mc-manifests-test`) + 124 Python + 55 Go |

### Decisões arquiteturais finais

| Decisão | Escolha | Justificativa |
|---------|---------|---------------|
| TUI | `gum` (Charm) | Single binary, `extra/gum` (Arch official), moderno, com `filter` (fuzzy) |
| Fallback TUI | `read`-based (ask_value/ask_confirm) | Garante funcionamento em CI/Arch limpo sem a ISO |
| Versão MC | manifest dinâmico por loader | Atual automaticamente; não fica preso a default hardcoded |
| Modpacks | API Modrinth v2 + `mrpack-install` | Catálogo sempre atual; compatibilidade server-side |
| Sugestão versão | heurística semântica (minor → major → latest) | UX: nunca trava o usuário sem saída |
| SSH live ISO | `openssh` no pacote, `sshd` **não** auto-start | Mantém segurança do auto-login no tty1; usuário ativa manualmente se precisar |
| SSH host | `INSTALL_SSH=true` → usuário `crias` + sudo + `PermitRootLogin no` | Hardening por padrão; root proibido via SSH |
| Loaders | fabric/quilt/vanilla/forge/neoforge (sem paper) | `.mrpack` é o formato; paper não tem fluxo equivalente |
| Branch única | `main` (monorepo) | Sem complexidade de merge; `discord-agent/` e `discord-bot/` como subdirs |
| Agente: linguagem | Go 1.23 | Binário estático, 5-10 MB RAM ocioso, sem runtime |
| Bot: linguagem | Python 3.12 + discord.py 2.x | Ecossistema maduro, Railway nativo |
| Templates `.service` | `envsubst` com `${VAR}` | Elimina injection via sed em MOTD |
| Backup-engine | Hooks `backup_pre_hook`/`backup_post_hook` | Minecraft usa RCON save-lock; Terraria no-op |

---

## 🔮 Planejado (Pós-v1.2.1)

### Alta prioridade

- [ ] **Métricas Prometheus no agente** — `crias_agent_grpc_requests_total`,
  `crias_agent_rcon_errors_total`, `crias_agent_players_online`.
- [ ] **Wake-on-LAN endpoint** no agente — para ligar PC do jogador remotamente.
- [ ] **TLS nativo no agente** — não depender exclusivamente de Tailscale Funnel.
- [ ] **Agente Discord para Terraria** — tModLoader não tem RCON nativo; explorar
  console stream via journalctl para o `crias-bot` suportar Terraria.

### Média prioridade

- [ ] **Bridge chat Discord ↔ Minecraft** — mensagens do Discord aparecem no
  jogo via RCON `tell`; mensagens in-game aparecem no `#chat-minecraft`.
- [ ] **`/mc autoshutdown on/off`** — ativar feature do agente via slash command.
- [ ] **`/mc logs [n]`** — ultimas N linhas via `StreamConsole` com tail.
- [ ] **Cache Go modules no CI** — `actions/cache` com `~/go/pkg/mod`.
- [ ] **Cache pacman no CI** — job `build-iso` não cacheia `packages.x86_64`.
- [ ] **Scheduled run semanal** — `schedule: cron: '0 3 * * 1'` no `ci.yml`.

### Baixa prioridade

- [ ] **Dependabot/Renovate** — auto-update de deps Go e Python.
- [ ] **Refatorar `MINECRAFT_MOTD` default** para constante única.
- [ ] **Backup remoto via rsync** — `BACKUP_REMOTE_PATH` já declarado mas não implementado.
- [ ] **Webhook de notificação de backup** — `BACKUP_NOTIFY_WEBHOOK` já declarado.

---

## 📊 Cobertura de testes atual

| Suíte | Tests | Status |
|-------|-------|--------|
| `tests/run-all.sh` (orquestrador) | 26 testes bash + 124 Python + 55 Go | ✅ Todos PASS |
| `tests/tui-fallback-test.sh` (novo v1.2.0) | 13 checks (caminho fallback sem gum) | ✅ Todos PASS |
| `tests/mc-manifests-test.sh` (novo v1.2.0) | 28 checks (parsing + sugestão, com fixtures) | ✅ Todos PASS |
| `tests/install-contracts.sh` | 7 contratos (incl. rejeição de `paper`) | ✅ Todos PASS |
| `discord-bot/tests/` (pytest) | 124 testes Python | ✅ Todos PASS |
| `discord-agent/internal/{config,rcon,events,server}/` | 55 testes Go (config=19, rcon=12, events=6, server=18) | ✅ Todos PASS (`-race`) |
| `tests/iso-initramfs-validate.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |
| `tests/iso-live-credentials-validate.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |
| `tests/iso-qemu-boot.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |

### Lacunas de cobertura conhecidas

- **Caminho `gum` (com TTY)**: não é testado em CI (precisa de TTY interativo).
  O caminho fallback é coberto por `tui-fallback-test.sh`. O caminho `gum` é
  exercitado manualmente na ISO live.
- **Chamadas de rede** (`mc_fetch_*`): não são mockadas em CI (precisariam de
  fixtures que simulassem respostas da API Modrinth/Mojang). As funções de
  `parse` e `suggest` são testadas com fixtures; as de `fetch` são wrappers
  finos sobre `curl`.
- `discord-agent/internal/server/server.go` (gRPC handlers) — algumas RPCs de
  streaming ainda usam mocks simplificados.

---

## 📝 Changelog

Veja [CHANGELOG.md](CHANGELOG.md) para o histórico detalhado de versões.

