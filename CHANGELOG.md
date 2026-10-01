# Changelog

Todos os mudanças notáveis do projeto Crias-Server serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [1.3.0] — 2026-F1 (login fix + bootstrap)

### Corrigido

- **Bug crítico de login na ISO**: a ISO estava inutilizável — ao bootar, o
  usuário via `archiso login:` mas não conseguia logar como `root` (senha
  travada no `/etc/shadow`) nem como qualquer outro usuário (nenhum existia).
  A cadeia `.bash_profile` → `.automated_script.sh` → `install.sh` nunca
  disparava porque login nenhum acontecia.
  - **Causa-raiz**: o commit `bb5cf64` (refatoração) removeu
    `archiso-profile/airootfs/root/customize_airootfs.sh` (que setava
    `root:crias` + criava `Server:crias`) sem adicionar substituto. O teste
    `iso-live-credentials-validate.sh` foi atualizado para afirmar que root
    está travado (hardening), mas nenhum mecanismo de login funcional o
    substituiu.
  - **Fix**: adicionado drop-in
    `archiso-profile/airootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf`
    com `--autologin root` (padrão archiso upstream). Root continua travado
    no shadow (hardening preservado); o autologin bypassa o prompt de senha
    apenas no tty1 físico.

### Removido

- **Auto-start quebrado**: removidos `archiso-profile/airootfs/root/.bash_profile`
  e `archiso-profile/airootfs/root/.automated_script.sh`. Rodar o instalador
  no live USB não faz sentido (efêmero, da RAM). O usuário faz `archinstall`
  primeiro, depois roda o instalador no host instalado.
- **Repo embutido em `/opt/crias-server/`**: removido o mecanismo que copiava
  20 arquivos do repo para a ISO em `/opt/crias-server/` (via
  `sync-airootfs.sh`). Era inútil pós-reboot (archinstall cria rootfs limpo;
  `/opt/crias-server/` não sobrevive). ISO fica menor.

### Adicionado

- **Bootstrap mínimo** (`crias-bootstrap.sh` na raiz do repo, embutido em
  `/usr/local/bin/crias-bootstrap` na ISO): consulta
  `api.github.com/repos/.../releases/latest`, baixa `crias-server-slim.zip` +
  `sha256sums.txt`, verifica SHA256 do zip, extrai em `/mnt/opt/crias-server/`
  (live ISO pós-`archinstall`) ou `/opt/crias-server/` (host instalado). No
  host instalado, roda `install.sh` direto; na live ISO, apenas extrai e
  imprime próximas instruções (evita problemas com `systemctl start` em chroot).
  - Username-agnostic: não assume nome de usuário (o usuário criado no
    `archinstall` é quem roda `install.sh` via `sudo`).
  - Sourceable (guard `BASH_SOURCE`): permite testes unitários das funções
    sem disparar a lógica de rede.
- **Novo teste** `tests/crias-bootstrap-test.sh`: valida sintaxe, sourceability,
    detecção de target, URL da API, verificação SHA256 (match/mismatch/ausente),
    extração de zip, e static checks (sem username hardcoded, usa curl+API+SHA256).
- **Asserção de autologin** em `tests/iso-live-credentials-validate.sh`: agora
  valida que o drop-in `getty@tty1.service.d/autologin.conf` existe e referencia
  `--autologin root` (teria pego o bug de login).
- **Modo `--deep-smoke` atualizado** em `tests/iso-qemu-boot.sh`: agora espera
  pelo prompt de shell de root pós-autologin (regex `root@<host>...#`), em vez
  do "Pressione [ENTER]" do `.automated_script.sh` removido. Falha com exit 23
  se detectar login prompt SEM autologin (regressão).

### Mudado

- **`archiso-profile/sync-airootfs.sh`**: simplificado — agora só copia
  `crias-bootstrap.sh` para `airootfs/usr/local/bin/crias-bootstrap` (executável)
  + escreve manifesto `.version` com commit + SHA256. Não copia mais 20 arquivos.
- **`archiso-profile/profiledef.sh` `file_permissions`**: atualizado para os
  novos arquivos (drop-in autologin, bootstrap, manifesto) e removidas as
  entradas dos arquivos deletados.
- **`tests/iso-embedded-scripts-validate.sh`**: reescrito para validar a nova
  estrutura (bootstrap + drop-in + manifesto), ao invés dos 20 arquivos.
  Inclui check de regressão (`.bash_profile`/`.automated_script.sh`/`customize_airootfs.sh`
  não devem existir).
- **`docs/security.md`**: corrigidas contradições sobre root no live ISO.
  Antes dizia "senha vazia" (falso — root está travado) e "auto-login" (falso
  antes do fix). Agora documenta corretamente: root travado no shadow, autologin
  via drop-in só no tty1, sshd não auto-sobe.
- **`archiso-profile/README.md`** e **`docs/tutorial.md`**: reescritos com o
  novo fluxo (boot → archinstall → crias-bootstrap → reboot → install.sh).

### Documentação (F2 — limpeza)

- **`config.env`**: corrigido comentário stale do tModLoader ("WIP — NÃO
  IMPLEMENTADO COMPLETAMENTE" → implementado em v1.2.1).
- **`docs/tmodloader.md`**: "Desde a v1.2.0" / "Implementado em v1.2.0" → v1.2.1
  (bate com CHANGELOG).
- **Contagem de testes**: removidos números hardcoded (22/24/26/28 bash, 124
  Python, 55 Go) inconsistentes entre `README.md`, `docs/README.md`, `ROADMAP.md`.
  Substituídos por frase genérica "bateria de testes bash + Python + Go — ver
  `tests/run-all.sh` para o total atual" (evita drift futuro quando testes são
  adicionados).
- **Tabela de tiers LOW/MID/HIGH**: consolidada — canônico em
  `docs/hardware-tuning.md`; `README.md` e `docs/tutorial.md` agora linkam em
  vez de duplicar a tabela.
- **Tabela de slash commands `/mc`**: consolidada — canônico em
  `discord-bot/README.md`; `README.md` agora linka em vez de duplicar.
- **`ROADMAP.md`**: atualizado para v1.3.0 com entradas F1 (login fix + bootstrap)
  na seção Implementado; contagens de testes trocadas por frase genérica.

### Pacotes (F3 — bump de versões externas)

Bumps validados localmente com Go 1.27.1 + Python 3.12.14 instalados no
sandbox de desenvolvimento. `go test -race` passou em todos os pacotes Go
(config, events, rcon, server); `pytest` passou 129 testes no discord-bot.

**Go (discord-agent)**:
- `google.golang.org/grpc`: v1.62.1 → v1.84.0
- `google.golang.org/protobuf`: v1.33.0 → v1.36.12
- `github.com/gorcon/rcon`: v1.3.5 → v1.4.0
- `golang.org/x/time`: v0.5.0 → v0.16.0
- `github.com/google/uuid`: v1.6.0 (mesma — já era a última)
- `gopkg.in/yaml.v3`: v3.0.1 (mesma — já era a última)
- Indiretos resolvidos por `go mod tidy`: `golang.org/x/net` v0.20.0→v0.57.0,
  `golang.org/x/sys` v0.16.0→v0.47.0, `golang.org/x/text` v0.14.0→v0.40.0,
  `google.golang.org/genproto/googleapis/rpc` atualizado. `github.com/golang/protobuf`
  v1.5.3 removido (não mais necessário como indireto).
- Diretiva `go` no go.mod: `1.23` → `1.26.0` (alguma dep nova exige Go 1.26+).

**Go runtime (CI + Dockerfile)**:
- `GO_VERSION`: '1.23' → '1.27.1' (necessário porque go.mod agora exige `go 1.26`)
- `FROM golang:1.23-alpine` → `golang:1.27.1-alpine` no Dockerfile

**Plugins protoc (Makefile + CI + Dockerfile)**:
- `protoc-gen-go`: v1.33.0 → v1.36.12
- `protoc-gen-go-grpc`: v1.3.0 → **v1.6.2** (não v1.84.0 — é módulo próprio
  com versionamento independente do grpc-go principal; descoberto ao testar)

**Python (discord-bot)**:
- `discord.py`: 2.4.0 → 2.7.1
- `grpcio`: 1.62.3 → 1.84.0
- `grpcio-tools`: 1.62.3 → 1.84.0
- `protobuf`: 4.25.3 → **7.36.2** (cascata: grpcio-tools 1.84 exige protobuf>=7.35;
  era S-C/high-risk mas validado com regeneração do grpc_gen)
- `python-dotenv`: 1.0.1 → 1.2.3
- `grpc_gen/` regenerado com grpcio-tools 1.84 (compatível com protobuf 7.x runtime)

**Mantido** (intencionalmente não bumped):
- `mrpack-install` v0.21.0-beta (confirmado pelo usuário como já na última)
- Python runtime 3.12 (3.14 disponível mas risk de incompatibilidade com discord.py
  2.7 / grpcio 1.84 não foi validado; fica pra fase futura)
- Dev deps Python (pytest 8.x, pytest-asyncio 0.23.x, pytest-cov 4.x, mypy 1.9.x)
  — pytest 9 foi instalado no sandbox e os 129 testes passaram, mas o pyproject
  segue pinado em ~=8.0.0 (bump de dev deps fica pra fase futura com gates de CI)

### Refatoração (F4 — código)

- **Bug `start-server.sh` non-fabric corrigido**: `-Dfabric.log.disable-ansi=true`
  era hardcoded para TODOS os loaders (linha 111). Agora gated em
  `MINECRAFT_LOADER == fabric || == quilt`. Para forge/neoforge/vanilla a flag
  era no-op (JVM seta mas server não lê), mas a correção semântica foi feita.
  - `write_minecraft_runtime_env` (minecraft-tuning.sh) agora inclui
    `MINECRAFT_LOADER` no `runtime.env` (default "fabric" para backward-compat
    com runtime.env antigo sem a var).
- **Helper `mktemp_crias_file` / `mktemp_crias_dir` em common.sh**: registry
  baseado em arquivo (não array em memória — array global + função sourced não
  propagava no bash 5.2 devido a quirk de escopo com `local`). EXIT trap lê o
  registry e limpa todos os temps ao final do script. Mais robusto que
  `trap ... RETURN` (que não dispara se a função é morta).
- **15 call sites refactorados** para usar `mktemp_crias_*` (remove o
  `trap 'rm -...' RETURN` manual): downloads.sh, stack-installer.sh,
  setup-cron.sh, minecraft/install.sh, terraria/install.sh (×2), install.sh (×9).
  Reduz ~30 linhas de boilerplate de trap.
- **`mc_parse_quilt_versions`**: verificado — já delega para `mc_parse_fabric_versions`
  (não havia duplicação real; STUDY-1 report foi impreciso). No-op.
- **Unificação dos managers (mc-manager.sh + tt-manager.sh)**: **deferrida** para
  um passe focado. Razão: os testes `setup-cron-manager-test.sh` e
  `arch-dry-install.sh` acoplam strings literais (`manager_need_root "$SELF"
  "setup-cron" "$@"` e `stat -c '%U'`) aos arquivos per-stack. A unificação
  exigiria atualizar esses testes simultaneamente, aumentando o risco. Os
  managers são ~95% idênticos (~540 linhas total, ~200 deduplicáveis) mas a
  refatoração merece seu próprio ciclo de validação com debug focado.

**Validação F4** (Go 1.27.1 + Python 3.12 no sandbox):
- `bash -n` em todos os .sh alterados: PASS
- `run-all.sh` completo: PASS=31, FAIL=0, SKIP=3 (só ISO-requiring)
- `mktemp_crias` testado end-to-end: cria temps, registry popula, EXIT trap
  limpa ao final (verificado com debug — array em memória falhava, registry
  file funciona).

### TUI + Ferramentas (F5)

- **`tui_help` / mini-wiki** (`tui.sh`): nova função acessível por
  `tui_help <topic>` exibe ajuda contextual (gum style + borda, ou print
  fallback). Tópicos: hardware-tier, loader, modpack, online-mode,
  tailscale, system-tuning, cleanup, ssh, agent, monitor. Callers em
  `install.sh` chamam `tui_help` antes dos 3 prompts mais complexos
  (tier, loader, modpack).
- **Migrados 3 `ask_confirm` → `tui_confirm`**: `install.sh` (tailscale
  outdated, cleanup stack, install agent). Unifica UX — todos os prompts
  agora usam `tui_confirm` (gum quando disponível, read fallback).
- **Fix `--selected` no `tui_choose`**: comentário dizia que `--selected`
  pré-selecionava o default, mas a chamada `gum choose` não passava a flag.
  Agora passa `--selected="$default"` (com guard: só se o default estiver na
  lista de options, pra não erroar o gum).
- **Theming centralizado**: `TUI_THEME_COLOR` (default 212) +
  `TUI_THEME_BORDER` (default normal) em `tui.sh`. `tui_msg` não mais
  hardcode `--foreground="212"`. Override via env vars sem mudar código.
- **Ferramentas de monitoramento integradas (T-C, sem glances)**:
  - `btop` + `ncdu` adicionados a `packages.x86_64` (pré-instalados na ISO).
  - `manager_cmd_monitor` em `manager-common.sh`: `monitor` (ou `monitor cpu`)
    lança `btop` (fallback `htop`); `monitor disk` lança `ncdu` no
    `SERVER_DIR`; `monitor net` lança `btop` (fallback `iotop-c`).
  - Subcomando `monitor` adicionado ao dispatch + show_help de mc-manager.sh
    e tt-manager.sh.
  - `install_monitor_tools_if_enabled` em `install.sh`: pergunta se instala
    btop+ncdu no host pós-archinstall (pré-instalados na ISO mas não no host
    instalado). Flag `INSTALL_MONITOR_TOOLS` em `config.env`.
  - `tui_help "monitor"` documenta o subcomando.
  - `iso-embedded-scripts-validate.sh` atualizado para checar btop+ncdu.

**Visão futura** (registrada para F6/GUI study): TUI como hub central
headless → eventualmente GUI web estilo CasaOS com ícones por categoria.
O `tui_help` e o subcomando `monitor` são passos nessa direção (centralização
de ajuda + acesso a ferramentas via interface).

### GUI study (F6 — estudo, sem código)

- **Novo doc** `docs/gui-feasibility.md`: estudo de viabilidade de GUI web
  estilo CasaOS. Avalia 6 opções (Cockpit, ttyd, wetty, CasaOS fork,
  sway+foot, custom Go webapp) com tabela de footprint/licença/fit/esforço.
  Recomenda **custom Go webapp** que reusa o `crias-agent` gRPC (sem herdar
  a dependência Docker do CasaOS real). Gateada por tier: LOW não, MID
  opcional, HIGH sim. Inclui arquitetura proposta, estrutura de repo,
  auth (token ou Tailscale Whois), e roadmap de 7 fases (G1-G7) pós-F8.
- **Decisão**: implementação da GUI fica para após F8 (revisão final). O
  estudo está documentado; o usuário decide se segue.

### Testes + QEMU (F7)

- **Novo teste `install-ssh-hook-test.sh`**: valida `install_ssh_if_enabled`
  via asserções static (function exists, called in main, INSTALL_SSSH em
  config-parser, sudoers drop-in `/etc/sudoers.d/crias-wheel` com `%wheel
  ALL=(ALL) ALL`, sshd drop-in `/etc/ssh/sshd_config.d/10-crias.conf` com
  `PermitRootLogin no`, useradd+chpasswd+usermod, systemctl enable+restart
  sshd, DRY_RUN skip, NON_INTERACTIVE skip, read -s senha, INSTALL_SSH=true
  documentado no README). 11 asserções.
- **Novo teste `install-monitor-hook-test.sh`**: valida
  `install_monitor_tools_if_enabled` (function exists, called in main,
  INSTALL_MONITOR_TOOLS em config-parser, `pacman -S btop ncdu`, DRY_RUN skip,
  NON_INTERACTIVE skip, subcomando `monitor` referenciado, btop+ncdu em
  packages.x86_64, manager_cmd_monitor em manager-common.sh, cmd_monitor +
  dispatch em ambos managers, tui_help "monitor" em tui.sh, fallback btop→htop).
  12 asserções.
- **`INSTALL_MONITOR_TOOLS` adicionada a `OVERRIDABLE_VARS`** em
  config-parser.sh (era uma variável de config que não estava na lista de
  overridable — agora captura env override corretamente).
- **QEMU `validate_qemu_log` melhorado (F7)**: novo warning (não failure) se
  o log tem `archiso login:` MAS não tem `root@archiso` — detecta exatamente
  o padrão do bug de login do F1 (login prompt apareceu mas autologin não
  disparou → root shell nunca aparece). Não falha o teste (falso positivo em
  boot lento) mas alerta para investigar o drop-in de autologin.
- **Novos testes adicionados a `run-all.sh` + `quick-script-tests.sh`**.
- **Validação**: run-all.sh completo: PASS=33 (era 31, +2 novos), FAIL=0,
  SKIP=3 (só ISO-requiring).

### Revisão final + Mutation test (F8)

- **Mutation test expandido** (9 mutações novas, total 22): cobre código de
  F1-F7 (crias-bootstrap.sh, start-server.sh, manager-common.sh, install.sh
  SSH/monitor). Resultado: **16 KILLED, 0 SURVIVED, 3 EXPECTED-SURVIVED
  (gaps documentados), 1 SKIPPED**. Mutation score: 100% dos não-esperados
  detectados.
  - **Testes strengthened** em F8 (matam mutações que sobreviveram):
    - `install-monitor-hook-test.sh`: pattern DRY_RUN broad `[DRY_RUN] Pulando`
      (match em 6 funções) → específico `[DRY_RUN] Pulando instalação de
      ferramentas de monitoramento` (mata M61). Adicionado check de ORDEM
      btop antes de htop (mata M40 — testa presença E ordem, não só presença).
  - **3 gaps documentados** (EXPECTED-SURVIVED, não falham CI):
    - M30: `start-server.sh` fabric gating não tem teste direto
      (minecraft-tuning-test não cobre o flag gating; apenas o tuning).
    - M50: `PermitRootLogin no` pattern broad (5 ocorrências em comentários +
      config; mutação da 1a = comentário, não quebra o teste que acha em outras).
    - M51: `useradd -m -s /bin/bash` 2 ocorrências (interactive + NON_INTERACTIVE;
      mutação da 1a não quebra o teste que acha a 2a).
  - M50/M51 revelam limitação dos **grep-based hook tests** (checam presença,
    não especificidade). Documentado; fortalecer exigiria multi-line patterns.
- **Unificação leve dos managers (F8)**: `resolve_self` extraído para
  `manager_resolve_self` em `manager-common.sh` (15 linhas × 2 = 30 linhas
  removidas de mc-manager.sh + tt-manager.sh). Unificação maior (show_help +
  case dispatch) **deferida** — exige atualizar testes com acoplamento
  literal (`manager_need_root "$SELF" "setup-cron"`, `stat -c '%U'`); feito
  o passe seguro (resolve_self) que não quebra nenhum teste.

### Unificação maior dos managers (F8 — pós-F8 inicial)

- **`manager-common.sh` expandido**: `cmd_start/stop/restart/status/logs`
  (delegações), `cmd_monitor` (wrapper), `cmd_backup`, `cmd_hardware_report`,
  `manager_show_help` (parameterizado via `MANAGER_DESC_CONSOLE` +
  `MANAGER_DESC_HEALTH`), `manager_dispatch` (case statement). Estas funções
  compartilhadas substituem as duplicadas em ambos managers.
- **mc-manager.sh + tt-manager.sh trimados**: removidas as funções que
  moveram para manager-common (cmd_start/..., cmd_backup, cmd_hardware_report,
  show_help, case dispatch). Mantidas per-stack: stack vars, detected_owner
  (`stat -c '%U'`), get_prop/get_cfg, cmd_setup_cron (com literal
  `manager_need_root "$SELF" "setup-cron" "$@"`), cmd_console, cmd_health,
  cmd_reconfigure_hardware. Adicionadas `MANAGER_DESC_CONSOLE` +
  `MANAGER_DESC_HEALTH` para o show_help compartilhado. Chamada final é
  `manager_dispatch "$@"`.
- **Resultado**: mc-manager.sh 275→209 linhas, tt-manager.sh 265→190 linhas,
  manager-common.sh 53→206 linhas. Net: ~55 linhas removidas + centralização.
- **Testes atualizados**: `install-monitor-hook-test.sh` agora checa
  `cmd_monitor` + `manager_dispatch` em manager-common.sh (não mais per-stack).
  `setup-cron-manager-test` (literal `manager_need_root`) preservado —
  cmd_setup_cron continua per-stack. `arch-dry-install` (`stat -c '%U'`)
  preservado — detected_owner continua per-stack. `quick-script-tests`
  (`cmd_health()`) preservado — cmd_health continua per-stack.

### Bug fix + limpeza (F8 final)

- **Bug do `tui_help` em chamadas multi-linha corrigido**: as inserções de
  `tui_help "loader"` e `tui_help "modpack"` (F5) estavam no MEIO de chamadas
  `tui_choose ... \` multi-linha, quebrando a continuação (`\` lia o tui_help
  como 4o argumento em vez das options). Movido para ANTES do `tui_choose`.
  Não foi pego antes porque `arch-dry-install` roda em NON_INTERACTIVE (pula
  os prompts). `tui_help "hardware-tier"` (antes de `tui_input` single-line)
  estava OK.
- **Limpeza de comentários fix-history**: removidas referências a
  `F1`/`F5`/`v1.3.0`/`v1.2.0`/`extraído`/`corrigido`/`removido em` em
  comentários de código (manager-common.sh, install.sh). Comentários agora
  só explicam WHY (não história de fixes). CHANGELOG mantém o histórico
  (é o lugar certo).
- **Validação F8 final**: run-all.sh: PASS=33, FAIL=0, SKIP=3. Mutation test:
  16 KILLED, 0 SURVIVED, 3 EXPECTED-SURVIVED. Todos os testes bash + Go + Python
  verdes. Cobre: F1 (login fix), F2 (docs), F3 (pacotes), F4 (start-server fix
  + mktemp), F5 (TUI + ferramentas), F6 (GUI study), F7 (testes), F8 (mutation
  + unificação leve).

### Resumo consolidado v1.3.0 (F1-F8)

8 fases entregues em 8 zips (crias-server-F1.zip → F8.zip) + 1 consolidado
final (crias-server-final.zip). Cada zip contém todos os arquivos do repo
no estado daquela fase.

| Fase | Entrega | Validação |
|---|---|---|
| F1 | Login fix + bootstrap (GitHub release download + SHA256) | PASS=29 |
| F2 | Limpeza docs (duplicatas, contradições, contagem genérica) | PASS=29 |
| F3 | Pacotes bumped (Go 1.27.1, grpc 1.84, protobuf 7.36, etc.) | PASS=31 (Go+Py locais) |
| F4 | start-server.sh fix + mktemp_crias helper (15 call sites) | PASS=31 |
| F5 | TUI refine (mini-wiki, --selected, theming) + btop/ncdu + monitor | PASS=31 |
| F6 | Estudo viabilidade GUI (doc, sem código) | PASS=31 |
| F7 | 2 hook tests novos (SSH + monitor) + QEMU autologin warning | PASS=33 |
| F8 | Mutation test (22 mutações, 16 KILLED) + unificação leve managers | PASS=33 |

## [1.2.1] — 2026-08-26

### Adicionado

- **tModLoader (Terraria com mods) — implementação completa**: o `TERRARIA_USE_TMODLOADER`
  agora funciona de verdade (antes era WIP). Substitui o binário vanilla do Terraria
  pelo tModLoader quando habilitado. Mesma porta (7777), mesmo diretório, mesma
  service unit (`terraria.service`).
  - Nova biblioteca `shared/lib/tmodloader.sh`: fetch dinâmico de versões via
    GitHub Releases API, catálogo curado de mods (Calamity, Thorium, Magic Storage,
    Recipe Browser), download via SteamCMD (App ID 1281930), geração de
    `Mods/enabled.json` e `Mods/install.txt`.
  - `install.sh` com prompts TUI: seleção de versão (busca fuzzy), e 3 fontes
    de mods (catálogo curado com multi-seleção / sem mods / Workshop IDs manuais).
  - `terraria/install.sh`: `download_and_install_tmodloader()` baixa
    `tModLoader.zip` do GitHub, extrai em `server/`, instala deps do .NET 8.
  - `terraria/start-terraria.sh`: detecta tModLoader (se
    `server/LaunchUtils/ScriptCaller.sh` existe) e usa `ScriptCaller.sh` com
    flags `-server -config -steamworkshopfolder -tmlsavedirectory`.
  - `terraria/backup-cron.sh`: inclui `Mods/` e `Worlds/` automaticamente
    quando tModLoader está instalado.
  - Novo `stack_install_mods` hook no `shared/lib/stack-installer.sh`.
  - Novas variáveis em `config.env`: `TERRARIA_TMODLOADER_VERSION`,
    `TERRARIA_TMODLOADER_MODS` (CSV de Workshop IDs).
  - Novo teste `tests/tmodloader-test.sh` (23 checks) + fixture
    `tests/fixtures/tmodloader-releases.json`.
  - Nova documentação `docs/tmodloader.md`.

### Corrigido (bugs pré-existentes encontrados em revisão milimétrica)

**Shell (4 bugs)**:
- **S1** (médio) `minecraft/start-server.sh:74-78`: recálculo de heap sobrescrevia
  config de produção (`-Xms==-Xmx`) quando `min >= max`. Agora só corrige se
  `min > max` (config genuinamente inválida).
- **S2** (baixo) `shared/lib/backup-engine.sh:184`: trap EXIT nunca limpo após
  sucesso, causando `save-on` duplicado em callers que sourceiam a lib.
- **S3** (baixo) `shared/lib/backup-engine.sh:51`: validação de `runtime.env`
  não cobria `$(...)` (command substitution). Adicionado `\$\(` ao regex.
- **S4** (baixo) `terraria/start-terraria.sh:39`: `ldd` retornava não-zero para
  binários estáticos também, abortando erroneamente. Mudado para aviso.

**Go (9 bugs em `discord-agent/`)** — corrigidos via subagente, 55 testes passam:
- **G1** (alto) `server.go`: `SendRconCommand` check de RCON-disabled era
  unreachable (NewClient nunca retorna nil). Adicionado `!s.cfg.Server.RCON.Enabled`.
- **G2** (médio) `server.go`: headers `x-api-token` duplicados aceitos. Agora
  rejeita `len(tokens) > 1`.
- **G3** (médio) `server.go`: `subtle.ConstantTimeCompare` vazava tamanho do
  token via timing. Agora faz `sha256.Sum256` de ambos antes de comparar.
- **G4** (médio) `server.go`: `GetHealth` probeiava RCON mesmo quando desabilitado.
- **G5** (médio) `autoshutdown.go`: `runSystemctl` sem deadline podia bloquear
  goroutine para sempre. Adicionado `withDeadline`.
- **G6** (médio) `rcon/client.go`: timeout de 10s podia bloquear ~15s (mutex +
  dial). Agora usa `net.DialTimeout` pré-flight.
- **G7** (baixo) `server.go`: `getServiceUptime` podia retornar negativo. Clamp a 0.
- **G8** (baixo) `rcon/client.go`: `executeLocked` deixava `c.conn` quebrada
  após erro de dial. Agora close+nil.
- **G13** (baixo) `server.go`: `StopServer` reportava timeout não-clampado nos
  eventos. Agora reporta o valor clampado.

**Python (10 bugs em `discord-bot/`)** — corrigidos via subagente, 129 testes passam:
- **P1** (alto) `bot.py:532`: race condition no console stream — `finally` limpava
  estado incondicionalmente, corrompendo task de Admin B quando Admin A cancelava.
  Agora checa `asyncio.current_task() is self.bot._console_task`.
- **P2** (médio) `config.py`: `RECONNECT_MAX_DELAY` negativo causava busy-spin.
  Agora clampa a `>=1`.
- **P3** (médio) `agent_client.py`: `_handle_rpc_error` mutava channel sem lock,
  causando double-close. Agora adquire `_connect_lock`.
- **P4** (médio) `embeds.py`: codeblock injection via backticks. Agora sanitizeia
  runs de 3+ backticks para um único.
- **P5-P9, P11** (baixo): diversos — channel close documentado, stream cancel,
  host redaction, discord_token placeholder rejection, health_report length,
  rate-limiter comment.

**CI (5 bugs em `.github/workflows/ci.yml`)**:
- **C1** (médio) release job não validava artifacts antes de publicar —
  `mv ... 2>/dev/null || true` silenciava faltas. Adicionado step de validação.
- **C2** (médio) sem checksum re-verification. Adicionado `sha256sum -c` por-artifact.
- **C3** (médio) `cancel-in-progress: false` global desperdiçava runner minutes.
  Agora `!startsWith(github.ref, 'refs/tags/')`.
- **C4** (baixo) sem cache de pip em `setup-python`. Adicionado `cache: 'pip'`.
- **C6** (baixo) `pacman-key --init || true` silenciava falhas de keyring.
  Removido `|| true`.

### Testes

- **28 testes bash** (subiu de 27 com `tmodloader-test`), todos PASS.
- Mutation testing: 11 KILLED, 0 SURVIVED, 2 neutral sanity.
- Go: 55 testes passam (`go test -race`).
- Python: 129 testes passam (via subagente com deps instaladas).

## [1.2.0] — 2026-08-23

### Adicionado

- **OpenSSH na ISO**: pacote `openssh` agora vem pré-instado na ISO live
  (`archiso-profile/packages.x86_64`). O `sshd` **não** sobe sozinho no live
  ISO (mantém o comportamento seguro de auto-login no tty1); para iniciar
  manualmente no live: `systemctl start sshd`.
- **Configuração de SSH no host instalado**: o `install.sh` agora pergunta
  (no início, via TUI) *"Habilitar acesso SSH no servidor instalado?"*. Se sim,
  instala `openssh`, habilita `sshd.service`, cria o usuário `crias` com
  `sudo` (senha pedida interativamente, grupo `wheel`), e configura o drop-in
  `/etc/ssh/sshd_config.d/10-crias.conf` com `PermitRootLogin no` (hardening).
  Controlável via `INSTALL_SSH=true|false` em `config.env`.
- **TUI (Terminal User Interface)**: o instalador agora usa **`gum`** (Charm)
  para todos os prompts interativos — menus de seleção (`gum choose`), busca
  fuzzy (`gum filter`), confirmações yes/no (`gum confirm`) e entrada de texto
  (`gum input`). `gum` vem pré-instalado na ISO. **Fallback automático** para
  `read -p` (clássico) quando `gum` não está disponível (ex.: instalando em
  Arch limpo sem a ISO, ou em CI). Nova biblioteca `shared/lib/tui.sh`.
- **Seleção dinâmica de versão do Minecraft**: o instalador busca a lista de
  versões do manifest oficial do loader selecionado (Mojang, Fabric Meta, Quilt
  Meta, NeoForge maven, Forge maven) e oferece seleção via busca fuzzy. Snapshots
  são mostrados marcados visualmente se o usuário optar (default: só releases).
  Nova biblioteca `shared/lib/mc-manifests.sh`.
- **Seletor de modpacks (Modrinth)**: novo fluxo com 4 fontes:
  1. **Top 10 modpacks** (Modrinth, ordenado por downloads);
  2. **Buscar modpack por nome** (busca livre na API do Modrinth);
  3. **Vanilla** (só loader, sem modpack);
  4. **Slug Modrinth manual** (para slugs específicos).
  As versões do modpack são filtradas **server-side** pela compatibilidade com
  o loader + versão de MC selecionados. Se nenhuma versão for compatível, o
  instalador **sugere a versão de MC mais próxima** suportada pelo modpack
  (heurística semântica: exata → mesma minor → mesma major → mais recente).
- **tModLoader (WIP)**: adicionada flag `TERRARIA_USE_TMODLOADER` (default
  `false`) em `config.env` e stub em `terraria/install.sh`. Ainda não
  implementado completamente — apenas avisa que é WIP e continua com servidor
  vanilla. Reservado para futura instalação de mods no Terraria.
- **User-Agent obrigatório**: todas as chamadas à API do Modrinth agora incluem
  o header `User-Agent` identificado (`crias-server-installer/1.2.0`), conforme
  exigido pela [documentação oficial](https://docs.modrinth.com) (UA genérico é
  bloqueado).
- **Novos testes**:
  - `tests/tui-fallback-test.sh` — valida o caminho de fallback do TUI (sem
    `gum`): detecção de engine, atribuição de defaults em EOF, retorno de
    `tui_confirm`/`tui_filter` em EOF, seleção numerada.
  - `tests/mc-manifests-test.sh` — valida parsing de manifests (Mojang, Fabric,
    Modrinth search, Modrinth project versions), extração de slug/version_number,
    sugestão de versão próxima, rejeição do loader `paper`, e inputs vazios.
    Usa fixtures JSON em `tests/fixtures/` (sem rede).
  - `tests/install-contracts.sh::run_paper_loader_rejected_contract` — valida
    que o loader `paper` é rejeitado pelo instalador em modo não-interativo.
  - Fixtures: `tests/fixtures/mojang-version-manifest.json`,
    `fabric-game-versions.json`, `modrinth-search-modpacks.json`,
    `modrinth-project-versions.json`.
- **Nova documentação**:
  - `docs/tui.md` — como o TUI funciona, `gum`, fallback, atalhos.
  - `docs/minecraft/modpacks.md` — guia do seletor de modpacks (top 10, busca,
    compatibilidade, sugestão de versão).
  - `CHANGELOG.md` — este arquivo (separado do ROADMAP.md).

### Alterado

- **Loaders suportados**: `paper` foi **removido** da lista de loaders aceitos
  (`fabric | quilt | vanilla | forge | neoforge`). O `validate_minecraft_inputs`
  agora rejeita `paper` explicitamente com mensagem clara. Justificativa: o
  fluxo de modpacks usa `.mrpack` (formato Modrinth para Fabric/Quilt); o
  `paper` é um fork de servidor sem fluxo de modpack equivalente neste projeto.
- **Prompts interativos**: `select_server_type`, `prompt_global_options`,
  `prompt_minecraft_options` e `prompt_terraria_options` agora usam a TUI (`gum`
  com fallback) em vez de `read -p` direto. Ordem dos prompts atualizada
  (loader → versão dinâmica → modpack → online-mode → QoL).
- **Regex de versão do Minecraft**: aceita snapshots no formato `YYwNNa`
  (ex.: `25w03a`) além de versionamento semântico (`1.21.4`), já que a seleção
  dinâmica pode retornar snapshots.
- **`tests/iso-embedded-scripts-validate.sh`**: agora verifica que
  `openssh` e `gum` estão em `packages.x86_64`, e que `shared/lib/tui.sh` e
  `shared/lib/mc-manifests.sh` estão presentes no airootfs embutido.
- **`tests/run-all.sh`** e **`tests/quick-script-tests.sh`**: registram os novos
  testes (`tui-fallback-test`, `mc-manifests-test`).
- **`config.env`**: comentários PT-BR atualizados para `MINECRAFT_VERSION`,
  `MINECRAFT_LOADER` (sem paper), `MINECRAFT_MODPACK_SOURCE` (top-10/busca),
  `MINECRAFT_ADRENALINE_VERSION` (busca dinâmica). Novas seções para
  `INSTALL_SSH` e `TERRARIA_USE_TMODLOADER`.

### Segurança

- **`PermitRootLogin no`** aplicado no host instalado quando SSH é habilitado
  (drop-in `/etc/ssh/sshd_config.d/10-crias.conf`).
- Senha do usuário `crias` é pedida interativamente com `read -s` (sem echo);
  em `NON_INTERACTIVE`, o usuário é criado com senha bloqueada (login por
  chave pública apenas).
- Host keys SSH **não** são pré-bakeadas na ISO (geradas ephemeramente por
  `sshdgenkeys.service` no boot), evitando compartilhamento de chaves entre
  instâncias da ISO.

### Documentação

- `README.md` atualizado para v1.2.0 (recursos OpenSSH, TUI, modpacks
  dinâmicos, remoção do paper).
- `ROADMAP.md` atualizado com status v1.2.0 e itens WIP (tModLoader).
- `docs/tutorial.md` atualizado com o novo fluxo TUI.
- `docs/minecraft/README.md` atualizado (loaders sem paper, modpacks dinâmicos).
- `docs/security.md` com seção SSH expandida (live ISO + host instalado).
- `archiso-profile/README.md` com OpenSSH e `gum` na lista de pacotes embutidos.
- `docs/README.md` com índice atualizado.

## [1.1.0] — 2026-07-05

- ISO "pronta pra uso" com instalador embutido em `/opt/crias-server/`.
- Tailscale re-adicionado na ISO (disponível mesmo sem internet no boot).
- `sync-airootfs.sh` + `tests/iso-embedded-scripts-validate.sh`.

## [1.0.0] — 2026-06-10

- Release inicial: Minecraft + Terraria, tuning por hardware, hardening
  systemd, backup com RCON save-lock, agente Go + bot Discord, CI/CD com 12
  jobs paralelos.
