# ROADMAP — Crias-Server

> Visão consolidada do produto e das lacunas de validação. Registros de fases antigas permanecem como referência histórica; o estado atual deve ser conferido na branch `main` e nas execuções recentes do CI.

## Roadmap vigente — nova geração do Hub (25/11/2026)

Planejamento aprovado em dez etapas na [issue #22](https://github.com/ViniciusLopes7/Crias-Server/issues/22). Consulte o [ADR Go](docs/decisions/hub-go.md) e a [auditoria C00](docs/hub-c00-baseline.md). O Hub Bash/Gum continua sendo a implementação distribuída até a troca validada; o instalador Bash permanece. As referências antigas abaixo são históricas, não decisões vigentes para a nova interface. A GUI web não faz parte deste roadmap.

| Fase | Ciclo | Entrega e gate |
|---|---|---|
| A — Fundação | C00 | Auditoria, contratos, baseline e documentação. **Encerrado condicionalmente**; gates físicos/SSH antes de M3/C04 e carga/homologação em C10/C11. |
| A | C01 | PoC Go, Bubble Tea/Lip Gloss candidatos; eventos, PTY/SSH e restauração de terminal, build e benchmarks. |
| B — Interface e paridade | C02 | Crias Forest, layout híbrido, seis abas, foco, busca, header/rodapé e responsividade. |
| B | C03 | Coletores, dashboard, histórico limitado, perfis e alertas verificáveis. |
| B | C04 | Paridade de serviços, console/logs, heap, arquivos, Voice Chat, Chunky, backups, atualização e diagnóstico. |
| C — Expansão | C05 | Jogos: console integrado, jogadores, telemetria, Chunky, formulários, mods/MRPack e atualização controlada. |
| C | C06 | Sistema: serviços, SSH/Tailscale, Doctor, logs, disco e energia. |
| C | C07 | Hardware: CPU, perfis, bateria, refrigeração e potência conforme compatibilidade e validação. |
| D — Resiliência | C08 | Backups, retenção, validação em quatro níveis, preparação de restore, destinos opcionais. |
| D | C09 | Journal, locks, tarefas, auditoria, recuperação e save-on independente; concluir proteções críticas. |
| E — Consolidação | C10 | Profiling, benchmarks, testes prolongados, auditoria, QEMU, jogos e hardware reais. |
| E | C11 | Distribuição, migração real, rollback, fallback Bash, documentação e release autorizada. |

C01 autorizado em caráter experimental somente leitura; demais ciclos planejados. Ver decisão de saída no documento C00. Dependências principais: C00 → C01 → C02 → C03 → C04; C05/C06/C08 após C04; C07 após C03. Contratos de segurança desde C01 e proteções implementadas antes de cada ação de escrita sensível, ainda que o C09 consolide mecanismos compartilhados. C10 depende do escopo entregue em C04–C09 e C11 depende de C10.

**Marcos verificáveis:** M1/C01 protótipo; M2/C03 interface e métricas reais; M3/C04 paridade experimental; M4/C07 expansão condicionada à segurança; M5/C09 resiliência; M6/C11 entrega padrão. A TUI experimental pode coexistir com Bash; nomes candidatos `crias-tui-next` e `--legacy` serão validados antes da distribuição. `--doctor` deve permanecer independente. Sem reinstalar jogos/host.

Escopo essencial: interface, monitoramento, paridade, console, heap, Chunky, Voice Chat, atualização/Doctor, backups/restore e controles de hardware suportados. Extensões condicionais/futuras: editor nativo, múltiplas instâncias, novos jogos, automação energética, GPU avançada, curvas não homologadas, integrações especiais e temas. Requisitos P1/P2 permanecem rastreados no épico; adiar com justificativa explícita, não eliminar silenciosamente.

Governança: política de engenharia vigente, commits atômicos, PRs coerentes, CI e evidências por SHA, main estável, merge/release conforme autorização. Segurança, testes, desempenho e documentação são transversais. Não declarar marco concluído por checklist sem evidência.

---

## Estado atual e histórico de implantação (releases de novembro de 2026)

> A tabela abaixo mantém marcos históricos das versões 1.2.x/1.3.0 para rastreabilidade. O mecanismo vigente de publicação usa tags datadas (por exemplo, `v2026.11.22-9496a5f`), não a indicação de versão deste cabeçalho.

### Consolidação de qualidade — prioridade atual

- [x] Base de critérios, documentação de arquitetura e inventário inicial preparados para revisão.
- [ ] Homologar princípios após merge e evoluir métricas com referências por SHA.
- [ ] Refatorar duplicações verificadas com testes antes/depois e sem novos recursos.
- [ ] Homologar memória, RCON/Chunky, backup e atualização com mundo de teste real.
- [ ] Corrigir documentação histórica ainda vinculada à antiga ISO, mantendo apenas o que for necessário para consulta.

### Marcos históricos implementados

> **Nota**: ISO customizada removida — use a ISO oficial do Arch Linux. ISO customizada é um objetivo futuro quando o projeto tiver maturidade.

### Componentes do repositório

| Componente | Status | Detalhes |
|------------|--------|----------|
| **Bug de login na ISO (F1)** | Histórico, descontinuado | Correção antiga de archiso; não integra o fluxo atual baseado na ISO oficial Arch. |
| **Bootstrap mínimo (F1)** | ✅ (v1.3.0) | `crias-bootstrap.sh` baixa a release do GitHub com verificação SHA256 em vez de embutir o repo inteiro na ISO. Username-agnostic. |
| **tModLoader (Terraria com mods)** | ✅ (v1.2.1) | `shared/lib/tmodloader.sh` — GitHub Releases dinâmico, catálogo curado (Calamity, Thorium, etc.), SteamCMD, `Mods/enabled.json`. Substitui vanilla quando `TERRARIA_USE_TMODLOADER=true`. |
| **OpenSSH no host** | ✅ (código atual) | Instalador configura o serviço SSH no Arch instalado; referências a `packages.x86_64` pertencem à ISO antiga. |
| **TUI (gum)** | ✅ (código atual) | `shared/lib/tui.sh` tem fallback `read`; instalação do `gum` é feita no Arch de destino, não por ISO customizada. |
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
| SSH live ISO (histórico) | Descontinuado | Decisão aplicável à ISO customizada antiga, não ao fluxo atual de instalação. |
| SSH host | `INSTALL_SSH=true` → usuário `crias` + sudo + `PermitRootLogin no` | Hardening por padrão; root proibido via SSH |
| Loaders | fabric/quilt/vanilla/forge/neoforge (sem paper) | `.mrpack` é o formato; paper não tem fluxo equivalente |
| Branch única | `main` (monorepo) | Sem complexidade de merge; `discord-agent/` e `discord-bot/` como subdirs |
| Agente: linguagem | Go (CI atualmente em 1.27.1) | Build do agente em Go; consumo real em execução requer medição no host. |
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

