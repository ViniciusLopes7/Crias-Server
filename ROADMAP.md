# ROADMAP — Crias-Server

> Status de implementação e próximos passos.
> Última atualização: 2026-06-29.

## ✅ Implementado (v1.0.0)

### Branch `main` (única, monorepo)

| Componente | Status | Detalhes |
|------------|--------|----------|
| **Refactoring shell** | ✅ | 3 novas libs compartilhadas (`stack-installer.sh`, `backup-engine.sh`, `setup-cron.sh`) reduziram ~40% da duplicação MC/TT |
| **Hardening systemd** | ✅ | `envsubst` em templates `.service` (elimina injection via sed), `CapabilityBoundingSet=`, `SystemCallFilter=@system-service`, `LockPersonality`, `ProtectHostname`, `ProtectClock`, `RemoveIPC` |
| **Supply chain** | ✅ | SHA256 obrigatório em `download_and_verify`, `mrpack-install` pinado em `v0.21.0-beta` + checksum real, `packages.lock` com versões mínimas |
| **Tuning por hardware** | ✅ | Detecção RAM/CPU/disco → tier LOW/MID/HIGH; thresholds configuráveis em `config.env`; skip automático em container/VPS |
| **Backup com RCON save-lock** | ✅ | Engine unificado com hooks pre/post; `save-off`+`save-all` antes, `save-on` depois |
| **Agente Go** (`discord-agent/`) | ✅ | gRPC `ServerControl` (7 RPCs) + `EventBus` (1 RPC), PlayerMonitor (30s), HealthMonitor (5min), AutoShutdown, `subtle.ConstantTimeCompare` em token, `sync.Mutex` em RCON |
| **Bot Discord** (`discord-bot/`) | ✅ | discord.py 2.x, slash commands `/mc start|stop|restart|status|players|say|console|health`, `asyncio.Lock` em `connect()`, backoff exponencial 1s→60s, cache de status 15s |
| **Eventos push** | ✅ | `ServerStarted`/`Stopped`, `PlayerJoined`/`Left`, `HealthWarning` → bot posta em `#controle` |
| **Streaming console** | ✅ | `StreamConsole` RPC (journalctl -f) → bot posta em `#console` com buffer 2s + chunks 1800 chars |
| **CI/CD** | ✅ | Workflow único `ci.yml` com 9 jobs paralelos + release unificado (ISO + slim.zip + full.zip + agent binaries + sha256sums) |
| **Releases** | ✅ | Release unificado em tag `v*`: ISO + `crias-server-full.zip` + `crias-server-slim.zip` + `crias-agent-linux-{amd64,arm64}` + `sha256sums.txt` (+ GPG sig opcional) |
| **Testes** | ✅ | 22 testes bash + 36 testes Python + 3 testes Go (race-safe) |

### Decisões arquiteturais finais

| Decisão | Escolha | Justificativa |
|---------|---------|---------------|
| Branch única | `main` (monorepo) | Sem complexidade de merge entre branches; `discord-agent/` e `discord-bot/` como subdirs |
| Agente: linguagem | Go 1.22 | Binário estático, 5-10 MB RAM ocioso, sem runtime |
| Agente: protocolo | gRPC + protobuf | Streaming bidi + tipagem forte + codegen Go/Python |
| Agente: escuta | `127.0.0.1:8473` apenas | Tailscale Funnel faz proxy HTTPS externo |
| Agente: auth | Token via metadata gRPC | `subtle.ConstantTimeCompare` previne timing attack |
| Agente: hardening | `MemoryMax=32M`, `CPUQuota=10%`, `MemoryDenyWriteExecute=yes` | Go é AOT: seguro aplicar W^X |
| Bot: linguagem | Python 3.12 + discord.py 2.x | Ecossistema maduro, Railway nativo |
| Bot: hospedagem | Railway | Zero config de infra, deploy via Git |
| Bot: estado | Stateless com cache curto (15s) | Fonte da verdade é sempre o agente |
| Templates `.service` | `envsubst` com `${VAR}` | Elimina injection via sed em MOTD |
| Stack-installer | Hooks específicos por stack | Reduz ~40% de duplicação sem perder flexibilidade |
| Backup-engine | Hooks `backup_pre_hook`/`backup_post_hook` | Minecraft usa RCON save-lock; Terraria no-op |

---

## 🔮 Planejado (Pós-v1.0.0)

### Alta prioridade

- [ ] **Métricas Prometheus no agente** — `crias_agent_grpc_requests_total`, `crias_agent_rcon_errors_total`, `crias_agent_players_online`, `crias_agent_memory_used_bytes`
- [ ] **Testes de integração Go** — mock de `exec.Command`/`journalctl` para cobrir `server.go` (atualmente sem `server_test.go`)
- [ ] **Wake-on-LAN endpoint** no agente — para ligar PC do jogador remotamente
- [ ] **TLS nativo no agente** — não depender exclusivamente de Tailscale Funnel (útil para quem quer usar Cloudflare Tunnel ou Caddy reverse proxy)

### Média prioridade

- [ ] **Bridge chat Discord ↔ Minecraft** — mensagens do Discord aparecem no jogo via RCON `tell`; mensagens in-game aparecem no `#chat-minecraft`
- [ ] **`/mc autoshutdown on/off`** — ativar feature do agente via slash command (já implementado no agente, falta o comando no bot)
- [ ] **`/mc logs [n]`** — ultimas N linhas via `StreamConsole` com tail
- [ ] **Cache Go modules no CI** — `actions/cache` com `~/go/pkg/mod` para acelerar builds
- [ ] **Cache pacman no CI** — `ci.yml` job `build-iso` não cacheia packages.x86_64 entre runs
- [ ] **Scheduled run semanal** — adicionar `schedule: cron: '0 3 * * 1'` ao `ci.yml` para capturar regressões em deps

### Baixa prioridade

- [ ] **Dependabot/Renovate** — auto-update de deps Go e Python
- [ ] **Refatorar `MINECRAFT_MOTD` default** para constante única (atualmente em 3 lugares)
- [ ] **`tests/quick-script-tests.sh`** — usar `find -print0` para paths com newlines (extremamente raro)
- [ ] **Backup remoto via rsync** — `BACKUP_REMOTE_PATH` já declarado em `config.env` mas não implementado
- [ ] **Webhook de notificação de backup** — `BACKUP_NOTIFY_WEBHOOK` já declarado mas não implementado
- [ ] **`server_test.go`** — testes unitários para `validateToken`, `runSystemctl`, `eventToProto` com mocks

---

## 📊 Cobertura de testes atual

| Suíte | Tests | Status |
|-------|-------|--------|
| `tests/run-all.sh` (orquestrador) | 22 testes bash | ✅ Todos PASS |
| `discord-bot/tests/` (pytest) | 36 testes Python | ✅ Todos PASS |
| `discord-agent/internal/{config,rcon,events}/` | 18 testes Go | ✅ Todos PASS (`-race`) |
| `tests/iso-initramfs-validate.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |
| `tests/iso-live-credentials-validate.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |
| `tests/iso-qemu-boot.sh` | ISO real | ⏭️ SKIP (requer ISO construída) |

### Lacunas de cobertura conhecidas

- `discord-agent/internal/server/server.go` (403 linhas, gRPC handlers) — **sem `server_test.go`**
- `discord-bot/src/crias_bot/agent_client.py` — testes só cobrem init/metadata/cache, não `connect()`/`close()`/RPCs
- `discord-agent/internal/rcon/client_test.go::TestClient_Execute_Mock` — faz conexão RCON real (deveria mockar `dialer`)

---

## 📜 Histórico

Para histórico detalhado de mudanças por versão, veja [docs/CHANGELOG.md](docs/CHANGELOG.md).
