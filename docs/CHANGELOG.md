# CHANGELOG — Crias-Server

Histórico de mudanças do projeto, seguindo [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/).
Formato: `MAJOR.MINOR.PATCH` ([SemVer](https://semver.org/lang/pt-BR/)).

## [Unreleased]

### Planejado
- Métricas Prometheus no agente (memory, gRPC latência, eventos emitidos)
- Wake-on-LAN endpoint no agente
- TLS nativo no agente (sem depender de Tailscale Funnel)
- Bridge chat Discord ↔ Minecraft (mensagens do Discord aparecem no jogo)
- Testes de integração com mock de systemctl/journalctl/mcrcon
- `server_test.go` cobrindo handlers gRPC e helpers
- Dependabot/Renovate para auto-update de deps Go e Python
- Scheduled run semanal do CI para capturar regressões em deps

## [1.1.0] — 2026-07-01

### Adicionado

#### ISO "pronta pra uso"
- `archiso-profile/sync-airootfs.sh` — script que copia os scripts do repo
  (install.sh, config.env, shared/lib/*, minecraft/*, terraria/*, branding)
  para dentro de `archiso-profile/airootfs/opt/crias-server/` antes do
  `mkarchiso`. A ISO gerada não precisa mais de internet para clonar o repo
  no primeiro boot.
- `archiso-profile/airootfs/root/.automated_script.sh` reescrito:
  - Detecta e roda o instalador embutido em `/opt/crias-server/install.sh`
    (modo EMBEDDED).
  - Fallback via `git clone` se a ISO foi construída sem sync (modo CLONE).
  - Avisa se internet está indisponível antes de rodar install.sh.
  - Valida checksum opcional via `INSTALL_SH_SHA256`.
- `archiso-profile/profiledef.sh` agora declara `file_permissions` para os
  arquivos embutidos (`/opt/crias-server/install.sh`, `config.env`, etc.).
- `tests/iso-embedded-scripts-validate.sh` — novo teste que valida 20
  arquivos essenciais embutidos, permissões executáveis, manifesto, e que
  install.sh embutido bate com o do repo.

#### Embeds padronizados do bot Discord
- `discord-bot/src/crias_bot/embeds.py` — fábrica centralizada de embeds com:
  - Paleta de cores consistente (success/error/warning/info/event/online/offline).
  - Thumbnail do escudo Crias em todos os embeds (branding).
  - Timestamp UTC + footer com versão do bot em todos os embeds.
  - Helpers específicos: `status_online`, `status_offline`, `players_list`,
    `health_report`, `command_result`, `say_confirmation`, `console_stream_*`,
    `event_embed`.
- `discord-bot/src/crias_bot/bot.py` refatorado:
  - Todos os 8 slash commands usam embeds (antes só 3 usavam).
  - `/mc start|stop|restart` agora usam `command_result()` com cor semântica.
  - `/mc say` usa `say_confirmation()` com codeblock da mensagem.
  - `/mc console` toggle agora é atômico via `asyncio.Lock` (evita task zombie
    se dois admins clicarem simultaneamente).
  - `_check_admin()`/`_check_moderator()` reduzem boilerplate de permissão.
  - `event_bridge` agora posta embeds (antes era texto puro).
- `discord-bot/tests/test_embeds.py` — 33 novos testes Python cobrindo todos
  os builders de embed.

#### Agente Go: campos populados que vinham vazios
- `GetStatus` agora popula `hardware_tier` (do config), `memory_used_mb` e
  `memory_max_mb` (lidos de `systemctl show -p MemoryCurrent/MemoryMax`).
- `GetHealth` agora popula `port` (do config `server_port`) e `port_listening`
  (testado via `net.DialTimeout` em 1s). `Healthy` agora considera porta em
  escuta, não só RCON.
- `config.go` — adicionados campos `ServerPort` e `HardwareTier` em
  `ServerConfig`.
- `install.sh` gera `agent.yaml` com `server_port` e `hardware_tier`.
- `agent.example.yaml` atualizado com os novos campos.

### Removido

#### ARM64 do agente Go
- `.github/workflows/ci.yml` — `build-agent` matrix agora é linux/amd64 only.
  Antes buildava arm64 também (~5-10 min de CI sem uso real).
- `discord-agent/Makefile` — `build-all` agora é alias de `build-linux-amd64`.
  Target `build-linux-arm64` removido. Cross-compile manual continua possível
  via `make build BUILD_ARCH=arm64`.
- Referências a arm64 removidas de `README.md`, `docs/README.md`,
  `docs/CHANGELOG.md`, `ROADMAP.md`, `discord-agent/README.md`.

#### Tailscale na ISO (mantido após feedback)
- `archiso-profile/packages.x86_64` — `tailscale` mantido. Decisão revisada
  após feedback do maintainer: garantir disponibilidade mesmo sem internet no
  primeiro boot é mais importante que reduzir ~30-50MB da ISO. O `install.sh`
  detecta se já está instalado (comum em hosts que bootaram pela ISO Crias) e
  pula o download. Para hosts sem ISO, mantém fallback via pacman + repo oficial.

### Modificado

#### install.sh — instalação do Tailscale mais robusta
- `install_tailscale_if_enabled()` agora tem duas tentativas:
  1. `pacman -S --needed --noconfirm tailscale` (repo Arch oficial).
  2. Fallback: adiciona repo `[tailscale]` ao pacman.conf, importa key
     `999EAC3D9BD5B7F7`, e instala via `pacman -Syy`.
- Trata caso em que Tailscale já está instalado (skipa download).
- Em caso de falha dupla, retorna erro com instruções claras para instalação
  manual (antes falhava silenciosamente).

#### CI/CD
- `build-iso` job agora roda `sync-airootfs.sh` + `iso-embedded-scripts-validate.sh`
  antes do `mkarchiso`, garantindo que toda ISO publicada tenha o instalador
  embutido e validado.

#### Testes
- `tests/agent-install-hook-test.sh` agora valida os novos campos
  `server_port` e `hardware_tier` no agent.example.yaml.
- `tests/run-all.sh` adiciona PRE-PASS que roda `sync-airootfs.sh` para
  garantir que `iso-embedded-scripts-validate.sh` passe localmente.
- `tests/iso-embedded-scripts-validate.sh` (novo) valida 7 checks de
  integridade do airootfs antes do build da ISO.
- `tests/iso-qemu-validate.sh` (novo) valida o profile contra a documentação
  oficial do archiso (README.profile.rst):
  - `install_dir` ≤ 8 chars `[a-z0-9]`
  - `iso_label` ≤ 11 chars (limite FAT)
  - `bootmodes` e `buildmodes` com valores válidos
  - `file_permissions` com formato `["/path"]="uid:gid:mode"`
  - Estrutura de diretórios (airootfs/, syslinux/, grub/, etc.)
  - `mkinitcpio.conf` com hooks `archiso` + `archiso_loop_mnt`
  - `packages.x86_64` com pacotes obrigatórios (mkinitcpio, mkinitcpio-archiso)
  - Smoke test via QEMU (`run_archiso`) se ISO_PATH fornecido e QEMU disponível

#### Bug fix
- `archiso-profile/profiledef.sh` — corrigida sintaxe inválida
  `${git_short::5^^}` (bash não suporta substring + uppercase combinados
  dessa forma). Substituído por `printf '%.5s' | tr '[:lower:]' '[:upper:]'`.
  Sem essa correção, o `profiledef.sh` não podia ser sourceado standalone
  (ex: em testes), embora o `mkarchiso` funcionasse porque faz `declare -A`
  antes.

### Documentação
- `archiso-profile/README.md` reescrito: explica a estratégia "pronto pra
  uso", o que está embutido vs baixado sob demanda, troubleshooting.
- `discord-agent/README.md` — removida referência a arm64 como build
  suportado; mantida nota sobre cross-compile experimental.
- `README.md` (raiz) — Release consolidada agora lista apenas
  `crias-agent-linux-amd64` (antes era `amd64 + arm64`).

#### CI/CD fixes
- `discord-agent/Makefile` — corrigidas receitas que usavam 8 espaços em vez
  de tabs (causava erro `missing separator` no job `lint-go` do CI).
- `.github/workflows/ci.yml` `test-python` — removida matrix `[3.11, 3.12]`
  que criava 2 jobs duplicados. Agora roda apenas Python 3.12 (valor do
  `env.PYTHON_VERSION`).
- `.github/workflows/ci.yml` — novo job `test-iso-qemu` que faz boot real
  da ISO no QEMU (BIOS legacy + UEFI com OVMF) e valida:
  - Formato ISO 9660 + El Torito boot record
  - Kernel Linux inicializa em 30s
  - archiso hooks carregam
  - Estrutura da ISO (vmlinuz, initramfs, diretório arch/)
  O job `release` agora depende de `test-iso-qemu` — ISO só é publicada se
  passar no boot test.

## [1.0.0] — 2026-06-29

### Decisão de escopo

**Monorepo em branch `main` única.** O plano original previa branch `discord` separada para o agente Go e bot Python, mas foi decidido manter tudo em `main` com `discord-agent/` e `discord-bot/` como subdiretórios. Motivos:

- Simplifica CI (sem sincronização entre branches)
- Facilita desenvolvimento (sem merge entre branches)
- Releases `crias-server-slim.zip` já excluem `discord-agent/`, `discord-bot/`, `docs/` para quem quer apenas o installer shell

### Adicionado

#### Refactoring shell (branch `main`)
- `shared/lib/stack-installer.sh` — framework de hooks para installers (reduz ~40% duplicação)
- `shared/lib/backup-engine.sh` — engine unificado de backup com flock + retenção + hooks pre/post
- `shared/lib/setup-cron.sh` — wrapper parametrizado para timer systemd
- `shared/lib/common.sh` — `log()`/`warn()`/`err()` centralizados, `systemctl_quiet_or_warn()`, `is_virtualized()`, `generate_token()`
- `shared/lib/downloads.sh` — `download_and_verify()` com SHA256 obrigatório por default, retry backoff exponencial para HTTP 429/5xx, `download_modrinth_mod()` helper
- `packages.lock` — pinagem de versões mínimas de pacotes pacman críticos
- Hook `install_crias_agent_if_enabled()` em `install.sh` (cria user, baixa binário, gera token, sudoers, systemd unit com hardening)
- Variáveis novas em `config.env`: `MINECRAFT_QOL_MODS` (CSV), `MINECRAFT_MODPACK_SOURCE`/`SLUG`, `MRPACK_INSTALL_VERSION`/`SHA256`, `HW_LOW_TIER_MAX_*`, `HW_MID_TIER_MAX_*`, `VIRT_TUNING_BEHAVIOR`, `BACKUP_REMOTE_PATH`, `BACKUP_NOTIFY_WEBHOOK`, `INSTALL_AGENT`

#### Agente Go (`discord-agent/`)
- `proto/crias.proto` — gRPC com `ServerControl` (7 RPCs) + `EventBus` (1 RPC), campo `max_players` em `StatusResponse`
- `internal/config/` — parser YAML com defaults e validações + testes
- `internal/rcon/` — cliente RCON thread-safe (`sync.Mutex`), cache 30s, whitelist de comandos + testes
- `internal/events/` — bus pub/sub com filtros, slow subscriber não bloqueia + testes
- `internal/server/server.go` — gRPC com auth interceptor (`subtle.ConstantTimeCompare` em token), `StreamConsole` (journalctl -f), `SubscribeEvents`
- `internal/server/monitor.go` — `PlayerMonitor` (30s polling RCON) + `HealthMonitor` (5min passivo)
- `internal/server/autoshutdown.go` — para servidor quando vazio por N minutos (trata erro de `systemctl stop`)
- `cmd/crias-agent/main.go` — entry point com graceful shutdown (não usa `log.Fatalf` para não pular `defer`)
- `Makefile` — targets `proto`, `tidy`, `build`, `build-all`, `test`, `lint`, `clean`, `docker`
- `Dockerfile` — multi-stage com `scratch` final (~5-10 MB)
- `agent.example.yaml` — template sem secrets
- CI: workflow único `ci.yml` com 9 jobs paralelos (lint-shell, test-shell, test-agent, build-agent, test-bot, build-bot-docker, build-iso, validate-iso, release) — release unificado em tag `v*` com ISO + slim.zip + full.zip + agent binaries + sha256sums

#### Bot Discord (`discord-bot/`)
- `pyproject.toml` — Poetry config com discord.py 2.4, grpcio, pyyaml, python-dotenv
- `src/crias_bot/config.py` — carrega `.env`, valida obrigatórios, `@dataclass(frozen=True)`, `_parse_int_env()` com tratamento de `ValueError`
- `src/crias_bot/agent_client.py` — cliente gRPC async com `asyncio.Lock` em `connect()`/`close()` (previne race), backoff exponencial 1s→60s, cache de `GetStatus` (15s), suporte a Tailscale Funnel (HTTPS) e localhost (insecure)
- `src/crias_bot/bot.py` — `CriasBot` (discord.py 2.x) + `MinecraftCog` com slash commands `/mc start|stop|restart|status|players|say|console|health`, `event_bridge` task posta eventos em `#controle`, `_console_stream_loop` com buffer 2s + chunks 1800 chars
- `src/crias_bot/__main__.py` — entry point com logging configurado
- `.env.example`, `Dockerfile` (multi-stage Python 3.12 slim), `railway.json`
- Testes: `test_config.py` (13 testes), `test_bot_helpers.py` (12 testes), `test_agent_client.py` (6 testes)
- CI: `test-bot` job no `ci.yml` — ruff check + pytest + Docker build smoke

#### CI/CD + docs
- Workflow único GitHub Actions: `.github/workflows/ci.yml` com 11 jobs paralelos (lint + test + build) + release consolidada no final
- Release automation: tag `v*.*.*` cria release única com ISO + binário Go (amd64) + Docker image bot + source archives (full/slim) + checksums + assinatura GPG opcional
- `ROADMAP.md` consolidando status de implementação
- `docs/CHANGELOG.md` (este arquivo)
- 3 novos testes bash: `tests/stack-installer-test.sh`, `tests/envsubst-test.sh`, `tests/config-parser-eq-test.sh`, `tests/agent-install-hook-test.sh`
- `tests/run-all.sh` — orquestrador único que roda todos os testes bash + Python + sintaxe YAML/JSON

### Modificado

#### Refactoring shell
- `shared/lib/common.sh` — adicionadas funções `log()`/`warn()`/`err()` centralizadas (substituem `echo` direto), `systemctl_quiet_or_warn()`, `is_virtualized()`, `generate_token()`; removido trap SIGINT frágil em `ask_confirm` (usa exit code de `read`)
- `shared/lib/downloads.sh` — SHA256 agora obrigatório por default (`require_checksum=true`); retry backoff exponencial; `DRY_RUN` previne todas as requisições de rede
- `shared/lib/hardware-profile.sh` — `classify_hardware_tier()` lê thresholds de `config.env`; fallback defensivo para `HW_CPU_CORES`; `cat` → `read -r` em leituras de `/sys`
- `shared/lib/{stack-installer,backup-engine,setup-cron,system-tuning}.sh` — removido `set -u` de libs sourced (caller decide política de erro); pattern `"${ARR[@]:-}"` → `${ARR[@]+"${ARR[@]}"}` (não itera com string vazia)
- `shared/lib/stack-installer.sh` — trap EXIT agora salva e restaura trap anterior (não vaza para callers)
- `shared/lib/config-parser.sh` — `OVERRIDABLE_VARS` expandido; corrigido comentário enganoso sobre "export"
- `shared/lib/setup-cron.sh` — substituído `echo` por `print_step`/`print_warning` (logs centralizados); declaradas `local` vars
- `minecraft/install.sh` + `terraria/install.sh` — refatorados para usar `stack-installer.sh` via hooks; `mrpack-install` agora baixa `.tar.gz` ou `.pkg.tar.zst` (URL antiga `mrpack-install-linux` não existe mais no release v0.21.0-beta); QoL mods via CSV com `set -f` (previne glob)
- `minecraft/backup-cron.sh` + `terraria/backup-cron.sh` — refatorados para usar `backup-engine.sh` com hooks RCON
- `minecraft/setup-cron.sh` + `terraria/setup-cron.sh` — wrappers finos sobre `shared/lib/setup-cron.sh`
- `minecraft/minecraft.service` + `terraria/terraria.service` — migrados de `sed` com `__VAR__` para `envsubst` com `${VAR}`; hardening systemd expandido (`CapabilityBoundingSet=`, `SystemCallFilter=@system-service`, `LockPersonality=yes`, `ProtectHostname=yes`, `ProtectClock=yes`, `RemoveIPC=yes`, `RestrictSUIDSGID=true`, `RestrictRealtime=true`)
- `minecraft/start-server.sh` — `JAVA_OPTS` agora construído como array nativo (preserva flags com espaços)
- `minecraft/mc-manager.sh` + `terraria/tt-manager.sh` — usam `log()`/`warn()`/`err()` de `common.sh`; `show_help` gerado dinamicamente via `declare -F`
- `install.sh` — propagadas novas variáveis em `write_stack_env_file()`; adicionada `install_crias_agent_if_enabled()` no final de `main()`; validação de inputs antes de gerar `agent.yaml`/sudoers (regex estrito); `visudo -cf` valida sudoers após gerar; token **não** é impresso em stdout (apenas caminho do arquivo protegido)
- `archiso-profile/packages.x86_64` — adicionado `gettext` (necessário para `envsubst` no LiveCD)
- `archiso-profile/airootfs/root/.automated_script.sh` — adicionado `--needed` ao pacman; `CRIAS_REPO_REF` para pinnar tag; `SKIP_VERIFY=0` default (verifica GPG por padrão); `$(seq 1 20)` → `{1..20}` (bash builtin)
- `tests/arch-smoke.sh` — atualizado para validar sintaxe `${VAR}` (envsubst) em vez de `__VAR__` (sed)
- `tests/static-audit.sh` — regex `\btar\b` agora requer espaço após "tar" (não pega "tar" em paths de URLs)
- `tests/run-all.sh` — detecta Python dinamicamente (sem paths hardcoded); filename passado como argv (evita injeção); `mktemp` para log compartilhado

#### Go
- `internal/rcon/client.go` — adicionado `sync.Mutex` para proteger `conn`/`lastUse` (data race safe); `WhitelistedCommands` agora é `var` package-level (evita realocação); removido `rcon.WithDialTimeout` (não existe na v1.3.5)
- `internal/server/server.go` — `interface{}` → `any` (Go 1.22+); `subtle.ConstantTimeCompare` em `validateToken` (previne timing attack); `bytes.IndexByte` da stdlib substitui helper customizado
- `internal/server/autoshutdown.go` — tratado erro de `systemctl stop` (só publica `ServerStopped` se sucesso); `strconv.Itoa` substitui helper `formatInt`
- `cmd/crias-agent/main.go` — `log.Printf + return` substitui `log.Fatalf` (não pula `defer`); `defer signal.Stop(sigCh)`

#### Python
- `discord-bot/src/crias_bot/agent_client.py` — `asyncio.Lock` em `connect()`/`close()` (previne race); fecha channel anterior antes de reatribuir (previne FD leak); logging de falhas de `connect`; `assert` → `if ... raise` (removido com `-O`); import relativo `from .grpc_gen`; `async with` em streams gRPC (não implementado ainda — issue aberta)
- `discord-bot/src/crias_bot/config.py` — reordenado campos obrigatórios primeiro (dataclass não permite non-default após default); `_parse_int_env()` com tratamento de `ValueError`
- `discord-bot/src/crias_bot/bot.py` — `time.monotonic()` substitui `asyncio.get_event_loop().time()` (deprecated); removido bloco `if TYPE_CHECKING: pass` morto; `except Exception` restringido para erros de rede específicos
- `discord-bot/tests/test_config.py` — `pytest.raises(dataclasses.FrozenInstanceError)` substitui `pytest.raises(Exception)`
- `discord-bot/tests/test_agent_client.py` — removida `sys.path` manipulation duplicada (já feita em `conftest.py`)
- `discord-bot/Dockerfile` — build context na raiz do repo (não usa mais `COPY ../`); fix de import protobuf via `sed`
- `discord-bot/railway.json` — removidos comentários `#` (JSON não aceita); adicionado `watchPatterns`

### Corrigido
- `tests/arch-dry-install.sh` quebrava após refactoring porque chamava `deploy_minecraft_scripts`/`deploy_terraria_scripts` (removidas) — adicionados aliases compat nos installers
- `discord-bot/railway.json` tinha comentários `#` (JSON não aceita) — removidos
- `discord-bot/src/crias_bot/config.py` tinha `@dataclass(frozen=True)` com campo non-default após default — reordenado
- `discord-bot/Dockerfile` usava `COPY ../discord-agent/proto/` (Docker não permite `..` no build context) — reescrito
- `discord-bot/src/crias_bot/grpc_gen/crias_pb2_grpc.py` tinha `import crias_pb2` (absoluto) quebrando import — `sed` converte para `from crias_bot.grpc_gen import`
- `MRPACK_INSTALL_SHA256` placeholder falso (`b1c2d3e4...`) validava formato mas sempre falhava checksum — removido; SHA256 real aplicado: `718e2f9f7337cddd8992641b22e704786a5e70e744e661d51aa3494f7ddfd9d2`
- URL do mrpack-install `mrpack-install-linux` retornava 404 (release v0.21.0-beta não tem esse asset) — refatorado para baixar `.tar.gz` ou `.pkg.tar.zst` e extrair binário
- `shared/lib/backup-engine.sh` checava `zstd` antes de DRY_RUN, falhando em ambientes sem zstd — check movido para depois do early return de DRY_RUN
- `shared/lib/stack-installer.sh` typo "UsamosShell" → "Usamos shell"

### Removido
- Diretórios `.github/workflows/` vazios em `discord-agent/` e `discord-bot/` (GitHub Actions só lê `.github/workflows/` na raiz)
- `docs/plano-arquitetura.md` — plano original executado; histórico preservado neste CHANGELOG
- `docs/InstalacaoManual.md` — tutorial antigo para hardware específico (i3-6006U, 4GB RAM); tudo automatizado pelo `install.sh`
- `docs/Chunky.md`, `docs/EssentialCommands.md`, `docs/StyledChat.md` — consolidados em `docs/minecraft/mods.md`
- `docs/shared/` — consolidado em `docs/{hardware-tuning,security,restore}.md` na raiz de `docs/`

## Como atualizar para 1.0.0

### Usuários existentes (branch `main` anterior)

1. **Backup do estado atual**:
   ```bash
   sudo systemctl stop minecraft  # ou terraria
   sudo cp -a /opt/minecraft-server /opt/minecraft-server.bak.$(date +%Y%m%d)
   ```

2. **Pull da nova versão**:
   ```bash
   git pull origin main
   ```

3. **Reinstalar stack** (atualiza scripts em `/opt/`, templates `.service`, e instala `gettext` se faltar):
   ```bash
   sudo ./install.sh
   ```

4. **Validar**:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl start minecraft
   sudo /opt/minecraft-server/mc-manager.sh status
   ```

### Instalação do agente de controle remoto (opcional)

Após atualizar para 1.0.0, pode-se instalar o agente Go:

```bash
sudo INSTALL_AGENT=true ./install.sh
# ou interativo:
sudo ./install.sh
# → "Instalar agente de controle remoto (crias-agent)? [y/N]: y"
```

O token de autenticação é gerado e salvo em `/etc/crias/agent.yaml` (chmod 0640). Veja com:

```bash
sudo grep auth_token /etc/crias/agent.yaml
```

Configure no Railway conforme [discord-bot/README.md](../discord-bot/README.md).

### Breaking changes

- **`MINECRAFT_MOTD`**: continuamente suportado, mas agora processado via `envsubst` em vez de `sed`. Se o MOTD contiver `${...}`, será interpretado como variável de ambiente. Escapar com `$${...}` se necessário.
- **`mrpack-install`**: versão pinada em `v0.21.0-beta` com SHA256 `718e2f9f...`. Para usar outra versão, defina `MRPACK_INSTALL_VERSION` e `MRPACK_INSTALL_SHA256` em `config.env`.
- **`download_and_verify()`**: agora exige SHA256 por default (`require_checksum=true`). Para permitir download sem checksum (não recomendado), passe `require_checksum=false` como 4º argumento.
- **Templates `.service`**: sintaxe mudou de `__SERVER_USER__` para `${SERVER_USER}`. Quem tinha scripts customizados que faziam `sed -e 's|__SERVER_USER__|...'` precisa atualizar para `envsubst`.
- **`SKIP_VERIFY`** no `.automated_script.sh` da ISO: default mudou de `1` (skip) para `0` (verifica GPG). Para manter comportamento antigo: `SKIP_VERIFY=1`.

### Migração de config.env

Variáveis novas são opcionais com defaults sane. Nenhuma variável existente foi removida. Recomenda-se revisar `config.env` com o novo template para habilitar features como `MINECRAFT_QOL_MODS` e `INSTALL_AGENT`.
