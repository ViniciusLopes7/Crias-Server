# ROADMAP — Crias-Server

> Visão consolidada do produto e das lacunas de validação. Registros de fases antigas permanecem como referência histórica; o estado atual deve ser conferido na branch `main` e nas execuções recentes do CI.

## ✅ Implementado (v1.3.0)

> **Nota**: ISO customizada removida — use a ISO oficial do Arch Linux. ISO customizada é um objetivo futuro quando o projeto tiver maturidade.

### Componentes do repositório

| Componente | Status | Detalhes |
|------------|--------|----------|
| **Bug de login na ISO (F1)** | ✅ (v1.3.0) | Drop-in de autologin do root no tty1 (padrão archiso upstream). Auto-start quebrado removido. Root permanece travado no shadow (hardening preservado). |
| **Bootstrap mínimo (F1)** | ✅ (v1.3.0) | `crias-bootstrap.sh` baixa a release do GitHub com verificação SHA256 em vez de embutir o repo inteiro na ISO. Username-agnostic. |
| **tModLoader (Terraria com mods)** | ✅ (v1.2.1) | `shared/lib/tmodloader.sh` — GitHub Releases dinâmico, catálogo curado (Calamity, Thorium, etc.), SteamCMD, `Mods/enabled.json`. Substitui vanilla quando `TERRARIA_USE_TMODLOADER=true`. |
| **OpenSSH na ISO + host** | ✅ (v1.2.0) | `openssh` em `packages.x86_64`; `install.sh` pergunta se habilita SSH no host → cria usuário `crias` com sudo, `PermitRootLogin no` |
| **TUI (gum)** | ✅ (v1.2.0) | `shared/lib/tui.sh` — wrapper `gum` com fallback `read` automático; `gum` pré-instalado na ISO |
| **Versão MC dinâmica** | ✅ (v1.2.0) | `shared/lib/mc-manifests.sh` — busca manifests Mojang/Fabric/Quilt/NeoForge/Forge; seleção fuzzy; snapshots marcados |
| **Seletor de modpacks Minecraft** | ✅ (código) | Top-10 e busca Modrinth, slug, vanilla, `.mrpack` local/pendrive e URL HTTPS; valida o pacote e reconcilia versão/loader. |
| **Loaders** | ✅ (v1.2.0) | `fabric | quilt | vanilla | forge | neoforge` — `paper` **removido** |
| **Refactoring shell** | ✅ | 3 novas libs compartilhadas (`stack-installer.sh`, `backup-engine.sh`, `setup-cron.sh`) + `tui.sh` + `mc-manifests.sh` |
| **Hardening systemd** | ✅ | `envsubst` em templates `.service`, `CapabilityBoundingSet=`, `SystemCallFilter=@system-service`, etc. |
| **Supply chain** | ✅ (código) / ⚠️ (E2E) | Bootstrap verifica SHA256 fail-closed (CR-17); install.sh verifica SHA256 do binário do agente contra o asset .sha256 (CR-18). Validação em host real pendente |
| **Tuning por hardware** | ✅ | Detecção RAM/CPU/disco → tier LOW/MID/HIGH; skip automático em container/VPS |
| **Backup com RCON save-lock** | ✅ (código) / ⚠️ (E2E) | Engine unificado; `save-on` restaurado no sucesso E em erro/sinal (CR-02, idempotente); `save-all` fail-closed com 2 tentativas (CR-16); escopo inclui config+mods com `level-name` dinâmico (CR-13/14). Ensaio com RCON real pendente |
| **Agente Go** (`discord-agent/`) | ✅ | gRPC `ServerControl` (7 RPCs) + `EventBus`, PlayerMonitor, HealthMonitor, AutoShutdown |
| **Bot Discord** (`discord-bot/`) | ✅ | discord.py 2.x, slash commands `/mc start|stop|restart|status|players|say|console|health` |
| **Eventos push** | ✅ | `ServerStarted`/`Stopped`, `PlayerJoined`/`Left`, `HealthWarning` → bot posta em `#controle` |
| **Streaming console** | ✅ | `StreamConsole` RPC (journalctl -f) → bot posta em `#console` |
| **CI/CD** | ✅ (automação) | Workflow `ci.yml` com lint, testes por linguagem, Java 21/25, Arch container, Arch QEMU com systemd e build/release condicionais. |
| **Testes** | ✅ (Bash/Go/Python/VM) / ⚠️ (homologação) | Há VM Arch + systemd, serviços reais e instalação até a EULA. Continuam faltando jogo com mundo ativo, RCON real completo e modpack grande de usuário. Consulte `docs/testing-qemu.md`. |

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

- [ ] **GUI web (custom Go webapp)** — dashboard CasaOS-style que reusa o
  `crias-agent` gRPC. Estudo de viabilidade em [docs/gui-feasibility.md](docs/gui-feasibility.md).
  Gateado por tier (LOW não, MID opcional, HIGH sim). Roadmap de 7 fases
  (G1-G7) documentado. Implementação pós-F8 (revisão final).
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
- [x] **Backup remoto via rsync** — implementado no `backup-engine.sh`; config propagada do `config.env` ao `runtime.env` (CR-15).
- [x] **Webhook de notificação de backup** — idem; falha de rsync notifica "local OK, remoto falhou".

---

## 📊 Cobertura e lacunas de testes

| Suíte | Tests | Status |
|-------|-------|--------|
| `tests/run-all.sh` (orquestrador) | Bateria de testes bash + Python + Go (total atual em `run-all.sh`) | ✅ Todos PASS |
| `tests/tui-fallback-test.sh` | 20 checks (fallback sem gum + fake-gum shadowing) | ✅ Todos PASS |
| `tests/mc-manifests-test.sh` (novo v1.2.0) | 28 checks (parsing + sugestão, com fixtures) | ✅ Todos PASS |
| `tests/install-contracts.sh` | 7 contratos (incl. rejeição de `paper`) | ✅ Todos PASS |
| `discord-bot/tests/` (pytest) | Testes Python (discord.py, config, agent_client, embeds) | ✅ Todos PASS |
| `discord-agent/internal/{config,rcon,events,server}/` | Testes Go por pacote (config, rcon, events, server) | ✅ Todos PASS (`-race`) |
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

## Estado atual de integração (novembro de 2026)

O seletor de `.mrpack` local/HTTPS e o conjunto de utilitários opcionais foram incorporados à `main`. A atualização antecipada do TUI, a recuperação em modo `--doctor` e a melhoria do cálculo de memória estão em revisão no [PR #12](https://github.com/ViniciusLopes7/Crias-Server/pull/12); o conteúdo desse PR **não deve ser descrito como já distribuído** até o merge e a publicação de uma nova release. O endurecimento do QEMU e a revisão editorial estão sendo avaliados na mesma branch.

A documentação de cenários validados e não validados encontra-se em [docs/testing-qemu.md](docs/testing-qemu.md).

