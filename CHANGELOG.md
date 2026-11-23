# Changelog

Todas as mudanças relevantes do projeto Crias-Server são registradas neste arquivo. Entradas antigas permanecem como histórico e não substituem a documentação operacional atual.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [Unreleased]

### Documentação e engenharia (proposto)

- Define princípios de qualidade e revisão, linha de base reproduzível, fronteiras da arquitetura e template de PR.
- Acrescenta relatório informativo de inventário e teste de contrato, sem modificar fluxos de produção nem impor redução artificial de linhas.
- Corrige referências documentais desatualizadas sobre Hub/Gum e critérios de validação; não altera mundo, mods, serviços ou tunning.

## [2026-11-22] — Hub, atualizações recuperáveis e administração cotidiana

### Adicionado

- **PR #24:** Hub com console RCON, arquivos sem root, Simple Voice Chat e atualização isolada de ferramentas administrativas.
- **PR #27:** consultas periódicas de progresso Chunky e controle do heap Java por modos automático, fixo ou personalizado.

### Corrigido

- **PR #25:** atualização resiliente a interrupção, com journal persistente, recuperação e testes de migração de releases reais pinadas.
- **PR #26:** navegação por setas do Gum sob substituição de comando e hierarquia dos menus.
- **PR #27:** console RCON SSH de conexões curtas, status compacto e formatação ANSI de encerramento.

### Limites de validação

- CI, QEMU e migração de arquivos foram aprovados; não substituem mundo modded ativo, RCON real prolongado ou testes de jogadores no host físico.



## [2026-11-21] — Proteções de operação após auditoria de prontidão

### Corrigido

- **SSH/sudo (PR #18):** a instalação não cria mais uma regra `%wheel` global capaz de modificar `sudo` de contas existentes. Somente contas administrativas recém-criadas recebem uma regra individual validada; políticas legadas são sinalizadas sem remoção automática.
- **QEMU/diagnósticos (PR #18):** a coleta do log integral dos loaders Minecraft é agora obrigatória para o CI aprovar. A contraprova identificou os seis avisos do Forge 1.20.1 como mensagens de inicialização sem erro fatal até a EULA.
- **Integridade dos mundos (PR #19):** `sync-chunk-writes=true` passa a ser o padrão para todos os tipos de disco, inclusive SSD/NVMe. A desativação requer configuração explícita `MINECRAFT_SYNC_CHUNK_WRITES=false`, com testes para opções inválidas.

### Critério de liberação

CI e QEMU validam código, instaladores e carregadores básicos. **Não equivalem à homologação de um mundo Minecraft real**: o CriasRealms completo, o primeiro boot após a EULA, backups/restauração, Tailscale entre computadores e 4–5 jogadores simultâneos ainda dependem de prova no host de destino.

## [2026-11-20] — Servidor estabilizado e pronto para testes de aceitação

### Corrigido

- Instalador: acesso SSH e etapa de autenticação Tailscale antes de baixar o Minecraft, com diagnóstico antecipado pelo `crias-tui --doctor`.
- Limites de memória: cálculo do heap com reserva para o sistema operacional, overhead nativo da JVM, RAM disponível e cotas efetivas dos cgroups.
- Reconfiguração de hardware: `MemoryMax` do systemd sincronizado com o heap configurado e validação/rollback dos limites persistentes.
- OOM: `Restart=no` no serviço do Minecraft, `OOMPolicy=stop` e `OOMScoreAdjust=200`. Falhas exigem início manual após diagnóstico; não há ciclo automático de reinício.
- Inicialização Java: bloqueio de parâmetros conflitantes de heap, RAM e memória direta nas variáveis `JAVA_TOOL_OPTIONS`, `JDK_JAVA_OPTIONS`, `_JAVA_OPTIONS` e no arquivo `user_jvm_args.txt` de Forge/NeoForge.
- Tuning global do host agora é opcional e conservador: sem mudanças automáticas de ZRAM, CPU governor ou I/O scheduler por padrão.

### Incluído e validado

- Importação de pacotes `.mrpack` locais, de pendrive ou por URL HTTPS; reconciliação de loader e versão efetivos.
- Mods opcionais de servidor, incluindo spark, Chunky e Skin Restorer, com detecção de duplicatas.
- CI com testes Shell, Go, Python, Java 21/25, builds do agente/bot e VM Arch Linux real via QEMU/systemd; Forge 1.20.1 validado com Java 17 até a EULA.
- Verificação real de SSH na porta 22, limites de memória, OOM artificial, bloqueio de reinícios, rollback e reconfiguração de RAM.

### Limite de homologação

A VM QEMU **não aceita a EULA nem cria mundo Minecraft**. Assim, a release valida a infraestrutura e a instalação dos loaders, mas **não certifica** o funcionamento integral do modpack CriasRealms 0.1.28, FPS/TPS em sessão multiplayer, nem backup/restauração com RCON real. É necessário validar em hardware físico antes de declarar a experiência de jogo homologada.

---

### Corrigido — Formato ruff reprovado na CI (2026-11-19, rodada 3)

O job `lint-python` da CI (`ruff format --check src/ tests/`) reprovou 3
arquivos que a verificação local não cobria — o `run-all.sh` só checava
**sintaxe** Python (`ast.parse`), nunca formato/lint:

- `src/crias_bot/bot.py`, `tests/test_agent_client.py` e
  `tests/test_console_stream.py` reformatados com `ruff format`
  (ruff 0.17.6 local; saída byte a byte idêntica à esperada pela CI).
  Mudança **somente de formatação**: AST dos 3 arquivos comparada contra a
  versão entregue anterior — idêntica, zero mudança semântica.
- **Fechamento do gap de processo**: `tests/run-all.sh` agora roda
  `ruff check src/ tests/` + `ruff format --check src/ tests/` a partir de
  `discord-bot/` — o mesmo contrato exato do job `lint-python` da CI
  (incluindo `working-directory`). SKIP silencioso quando `ruff` não está
  instalado localmente (ambientes mínimos); a CI permanece obrigatória.
  Contraprova por mutação: com o `bot.py` não-formatado o gate reprova
  (exit 1); com o formatado passa.

### Corrigido — Auditoria pré-entrega + contraverificação (2026-11-19, rodada 2)

Auditoria pré-entrega obrigatória (dois revisores independentes sobre o diff
completo) encontrou **3 P1, 5 P2 e vários P3** — todos corrigidos nesta
rodada, com contraprovas adicionadas à suíte (34 testes Bash no total):

- **P1 (A)**: `setup-cron.sh` (mc/tt) não resolvia as libs no
  `/usr/local/libexec/crias/lib` — o comando `setup-cron` quebrava em toda
  instalação nova. Corrigido com resolução libexec → .shared → repo.
- **P1 (A)**: snapshot de extras aninhados (`config/serverconfig.txt`) não
  criava o diretório-pai no snapshot — **toda reinstalação do Terraria
  abortava** no fail-closed. Corrigido (`mkdir -p` do dirname).
- **P1 (B)**: a validação EXP-51 com regex **citada** em `[[ =~ ]]` casava
  literal e rejeitava **qualquer level-name customizado** — backups 100%
  quebrados para mundos com nome próprio. Regex des-citado + `.`/`..` no
  case do engine + contraprova no backup-integrity-test (`reino` com
  sucesso; `../escape`, `-checkpoint`, `..`, `.` rejeitados).
- **P1 (B)**: `save-off` com falha de execução ignorava
  `BACKUP_REQUIRE_CONSISTENT=true` (prossegia best-effort). Agora aborta em
  modo strict.
- **P1 (B)**: `envsubst-test.sh` referenciava `$MC_OUTPUT` inexistente —
  quebraria o job `test-shell` da CI (o teste nunca havia rodado com
  envsubst presente no sandbox). Corrigido; teste agora valida AMBAS as
  units com systemd-analyze.
- **P2 (A)**: rollback executava a limpeza legacy quando a PREPARAÇÃO do
  snapshot falhava — apagava artefatos que a execução nem tinha tocado
  (contradizia o CR-04). Agora: flag `STACK_SNAPSHOT_COMPLETE`; sem snapshot
  completo o rollback é NO-OP.
- **P2 (A)**: `crias-tui.sh` detectava stacks pelos managers no game dir
  (removidos pelo EXP-34) — hub ficava cego. Detecta via units systemd +
  manager no libexec.
- **P2 (B)**: versão efetiva do modpack não alimentava JDK nem runtime.env
  (pack 26.x + config 1.21.x ressuscitaria o EXP-36). `_reconcile_effective_java`
  instala o JDK exigido e promove a versão do pack.
- **P2 (B)**: `_resolve_modpack_effective_versions` rodava também para
  `source=vanilla` e sobrescrevia a versão correta com a do slug default.
  Agora só nos ramos adrenaline/modrinth.
- **P2 (B)**: modpack Quilt recebia `--server-file server.jar` (conflito do
  EXP-39 valia só para base). Server-file derivado do loader em todos os ramos.
- **P2 (B)**: wizard perguntava QoL/extras após "vanilla puro" e descartava
  as respostas (CR-18). "Vanilla (só loader)" agora pergunta base limpa vs
  base+mods; perguntas de mods só quando serão aplicadas.
- **P2 (B)**: `TML_STEAMCMD_TIMEOUT` do config.env não chegava ao stack
  installer. Repassado no env file do stack.
- **P3 (A/B)**: guarda root-safe resolve symlinks antes do stat (manager via
  symlink de conveniência voltou a funcionar); `chown -R` do
  reconfigure-hardware do MC valida SERVER_DIR; `SETUP_CRON_SCRIPT` entra na
  guarda de ownership; extras do snapshot sob prefixo `extra/` (sem colisão
  com nomes reservados); perfil com BEGIN sem END é reconstruído em vez de
  descartar o resto; bootstrap restaura instalação legada se o swap do
  symlink falha e nunca apaga a release apontada pelo symlink atual; trap do
  backup compõe a limpeza de temporários; `.partial` órfãos de SIGKILL são
  varridos no próximo backup; `write_file_or_dry_run` cria segredos já com
  umask 077; `source` do common.sh sem `|| true`; hint de monitor e TODOS os
  docs apontam para o manager no libexec; bloco de hardening do security.md
  explicita a exceção do crias-agent (não "corrigir" de volta).
- **Novo teste** `download-modrinth-test.sh` (contraprovas CR-10/EXP-48/52:
  seleção primary, hash sha1/sha512/sha256 divergente rejeitado com remoção
  do jar, sem fallback de versão).



### Corrigido — Auditoria ampliada CR-01..CR-32 + EXP-33..EXP-65 (contraverificação 2026-11-19)

Entrega única (Opção B) com os 65 achados da auditoria ampliada contra o
commit `d57dd39`. 64 corrigidos; 1 falso-positivo documentado (CR-19 — a
chamada de `download_server_icon_if_set` já existe na linha 567 de
`minecraft/install.sh` no commit auditado; adicionada em `4370948`).

**Segurança / fronteira root x jogo (P0)**

- **EXP-33**: `/etc/profile.d/crias-server.sh` não faz mais `source` do
  `comandos.sh` (gravável pelo usuário do jogo) — o perfil recebe aliases
  ESTÁTICOS inline, root:root 0644, com bloco gerenciado idempotente e
  migração das linhas legadas.
- **EXP-34**: managers (`mc-manager.sh`/`tt-manager.sh`), `setup-cron.sh` e
  as libs administrativas mudam para `/usr/local/libexec/crias` (root:root).
  Managers recusam executar como root qualquer script gravável por não-root
  (`manager_assert_root_safe`); o deploy remove as cópias legadas do game
  dir; aliases/sudoers/agent.yaml apontam para o libexec.
- **EXP-35**: `validate_server_dir` agora é allowlist — apenas subdiretórios
  dedicados (`/opt/*`, `/srv/*`, `/var/opt/*`, `/home/*/*`, `/tmp/*/*`);
  raízes amplas (`/home`, `/opt`, `/srv`, `/var`, `/tmp`, `/run`, `/mnt`,
  `/media`) e áreas de sistema nunca são aceitas como alvo de `chown -R`.
  Teste novo `validate-server-dir-test.sh` (26 casos + bypass por symlink).
- **CR-02**: unit do agente sem `CapabilityBoundingSet=`/`AmbientCapabilities=`
  vazios (sudo setuid volta a funcionar; sudoers permanece a fronteira).
- **EXP-65**: drop-in do sshd preserva `PasswordAuthentication no` de hosts
  key-only e valida com `sshd -t` antes do restart.

**Startup Minecraft (P0)**

- **CR-01/EXP-59**: unit gerada em `mktemp --suffix=.service` dentro de
  `/etc/systemd/system` + publicação atômica por `mv -T` (o verify
  bloqueante do systemd-analyze falhava SEMPRE com nome sem extensão).
- **EXP-36**: Java exigido derivado da versão do jogo (26.x → `jdk25-openjdk`;
  1.20.5–1.21.x → `jdk21`), com validação de major version no launcher
  (`required_java_major`, snapshot `26w14a` incluso).
- **EXP-37**: sem modpack usa a CLI correta do mrpack-install v0.23.0
  (`mrpack-install server <loader> --minecraft-version <v>`); a forma antiga
  tratava o loader como nome de modpack.
- **EXP-38**: Forge 1.17+/NeoForge iniciam com `@user_jvm_args.txt`.
- **EXP-39**: Quilt usa `--server-file mc.jar` (o launcher do Quilt ocupa
  `server.jar`); `SERVER_JAR` persistido no runtime.env.
- **EXP-41**: pacote pacman só é usado se a versão BATER com o pin;
  verificação pós-instalação contra `MRPACK_INSTALL_VERSION`.
- **EXP-42**: versão efetiva do jogo/loader resolvida da API do Modrinth
  após instalar o pack — QoL/extras seguem a versão REAL do pack.

**Backups**

- **CR-04**: snapshot pre-instalação COMPLETO (unit, scripts, .shared,
  server.properties/serverconfig.txt, server.jar, server/, steamapps/) com
  manifesto restore/remove/leave; falha de snapshot aborta antes de
  modificar; rollback nunca apaga o que não pode restaurar.
- **CR-05**: `BACKUP_REQUIRED_DIRS` — mundo ausente é falha, não sucesso só
  com configs. Testado em `backup-integrity-test.sh`.
- **CR-06**: `BACKUP_REQUIRE_CONSISTENT=true` aborta backup sem RCON/mcrcon;
  modo best-effort (default) agora avisa em texto claro.
- **CR-07**: runtime.env carregado ANTES de montar o escopo
  (`backup_load_runtime_env`) — `BACKUP_INCLUDE_MODS=false` funciona.
- **CR-08**: runtime.env escrito com modo 0600 (webhook é credencial).
- **CR-13**: `BACKUP_RETENTION_DAYS`/`BACKUP_ZSTD_LEVEL` do config.env
  chegam ao runtime.env com precedência documentada (override > operador >
  tier); config.env agora vaza (`""` = automático por tier).
- **CR-15**: unit de backup com `ProtectHome=read-only` (chave SSH do rsync
  volta a ser legível; home segue protegido contra escrita).
- **CR-20**: `save-on` com falha mantém o lock ARMADO (EXIT trap tenta de
  novo) + alerta persistente `.crias-saveoff-alert`.
- **EXP-49**: tar grava em `.partial`, valida com `zstd -t` + `tar -tf` e
  publica com `mv` — arquivo truncado nunca vira backup "válido".
- **EXP-50**: nome com nanossegundos + sufixo; dois backups no mesmo segundo
  não se sobrescrevem (contraprova no teste de integridade).
- **EXP-51**: `level-name` validado (sem traversal/absoluto/opção) e tar com
  `--`.
- **EXP-54**: webhook com `--connect-timeout 10 --max-time 20`.
- **EXP-62**: DRY_RUN não notifica sucesso (é simulação).

**Mods / downloads / tuning**

- **CR-10**: sem fallback sem filtro de versão no Modrinth.
- **EXP-48**: hash sha1/sha512 da API verificado após download (+ sha256
  fixado opcional via `MOD_*_SHA256`); jar truncado é removido.
- **EXP-52**: seleção do arquivo `primary=true` com `.jar`.
- **CR-03**: `serverconfig.txt` do Terraria por merge — senha e chaves do
  operador preservadas no reconfigure-hardware (`.crias-bak` antes).
- **CR-11**: workshop tML só conta como instalado com `.tmod` real presente.
- **CR-26**: steamcmd com timeout configurável (`TML_STEAMCMD_TIMEOUT`,
  default 3600s) + log com as últimas linhas em caso de falha.
- **CR-17**: modo strict opcional (`MINECRAFT_MODS_STRICT`/
  `TERRARIA_MODS_STRICT`) transforma pendências em falha da instalação;
  default best-effort com resumo final.
- **CR-18**: `MINECRAFT_INSTALL_MODPACK=false` = servidor base limpo (QoL e
  extras desligados); para loader+mods sem pack, usar `source=vanilla`.
- **EXP-60**: RAM efetiva considera o limite do cgroup (v2/v1) em containers.

**Agente / bot (Go + Python)**

- **CR-09**: comandos Discord falham rápido com mensagem amigável quando o
  agente está offline (`ensure_connected` com timeout; retry infinito só na
  tarefa de fundo).
- **CR-14**: `crias-agent` no grupo `systemd-journal` (journalctl sem sudo).
- **CR-25**: install do agente com verify bloqueante (`.service`), enable
  bloqueante e estado PARCIAL explícito quando o restart falha.
- **CR-27**: RCON Go com dial limitado e mutex não segurado durante I/O —
  goroutine abandonada não trava chamadas seguintes.
- **EXP-44**: token do agente reutilizado em reinstalações (rotação via
  `AGENT_ROTATE_TOKEN=true`).
- **EXP-45**: parser RCON `list` estrito — resposta malformada é ERRO e
  bloqueia auto-shutdown (não conta como 0 jogadores).
- **EXP-46**: rate limit agressivo apenas para auth INVÁLIDA; tráfego
  autenticado usa limite generoso; mapa com teto e expiração.
- **EXP-47**: deadline do StreamConsole configurável
  (`features.console.stream_deadline_seconds`, default 300) + marcador
  final; o bot reabre a stream com backoff e cobre o intervalo.
- **EXP-53**: health exige a unit do jogo ativa (porta aberta de outro
  processo não é mais "saudável").
- **EXP-61**: logs no Discord com backticks neutralizados e
  `allowed_mentions=none`.
- **EXP-63**: cache de status invalidado após start/stop/restart.
- **CR-22**: healthcheck do Docker verifica heartbeat do bot (arquivo com
  idade máxima), não apenas imports.
- **CR-30**: README do bot com procedimento de primeiro deploy do sync.

**Distribuição / CI / testes**

- **CR-12**: artifacts ausentes (agente/bot) são bloqueantes na release.
- **CR-16**: bootstrap instala em `.releases/<timestamp>` com symlink
  atômico — atualização interrompida nunca mistura versões; mantém as 3
  últimas para rollback.
- **CR-21**: trap EXIT composto — limpeza de temporários do common.sh
  continua ativa após o run_stack_install.
- **CR-23**: `backup-saveon-success-test.sh` entra no job test-shell da CI.
- **CR-29**: `Makefile` com `test-all` (bash + go + python).
- **EXP-40**: bootstrap exibe tag/commit da release antes de instalar
  (main pode estar à frente da latest).
- **EXP-55**: envsubst-test valida as units do Minecraft E do Terraria em
  arquivos `.service` distintos.
- **EXP-56**: java-flags-test cobre o mapeamento versão→Java (bug real
  encontrado e corrigido: snapshot `26w14a` sem ponto).
- **EXP-57/49/50/62**: novo `backup-integrity-test.sh` — tar+zstd reais,
  restore byte a byte, colisão de nomes, falha de tar sem publicação, DRY_RUN
  sem notificação.
- **EXP-58**: ZIP slim não embute mais `tests/`.
- **EXP-64**: `GITHUB_TOKEN` lido de arquivo privado via `curl -H @file`
  (bootstrap e installer) — fora do argv dos processos.
- **CR-31**: instruções da ISO legada movidas para `docs/legacy-iso.md`.

### Segurança — notas operacionais da auditoria ampliada

- Managers agora vivem em `/usr/local/libexec/crias` — aliases antigos que
  apontavam para `/opt/<stack>-server/mc-manager.sh` são migrados
  automaticamente pelo installer (o perfil global é regerado).
- `docs/security.md` ganhou as seções "Fronteira root x usuário do jogo",
  "Hardening do agente", "SSH no host instalado" e "Verificação adicional
  da release" (limitação do checksum sem assinatura — CR-24).



### Corrigido — Auditoria externa CR-01..CR-28 (contra-verificação 2026-11-18)

- **CR-01 (P0)**: JVM 21 recusava as flags G1 experimentais
  (`G1NewSizePercent is experimental`, exit 1) — o servidor nunca subia.
  Fix: `-XX:+UnlockExperimentalVMOptions` antes das flags em
  `minecraft/start-server.sh`. Teste novo `java-flags-test.sh` (estático +
  smoke com a JVM real quando disponível).
- **CR-02 (P0)**: backup bem-sucedido deixava `save-off` ativo — o caminho
  de sucesso limpava o trap sem chamar o post-hook. Fix: trap armado ANTES
  do pre-hook + `save-on` explícito no sucesso (idempotente via guard).
  Teste novo `backup-saveon-success-test.sh` exige exatamente 1 `save-on`.
- **CR-03 (P0)**: `envsubst` recebia variáveis `local` (não exportadas) e
  gerava `User=`, `ExecStart=/start-server.sh`, `MemoryMax=M`. Fix: valores
  via env do comando (`env SERVER_USER=... envsubst`) + validação de campos
  vazios antes de instalar a unit. `envsubst-test.sh` reescrito SEM
  pré-export (o teste antigo mascarava o bug) com controle negativo.
- **CR-04 (P0)**: `if ! run_selected_stack_installer` desativava o errexit
  do subshell inteiro — falhas de download/pacman eram engolidas e a
  instalação reportava sucesso falso. Fix: chamada direta + EXIT trap no
  subshell para limpar o env file. Regra estática no `static-audit.sh`.
- **CR-05 (P0)**: `Requires=<jogo>.service` na unit de backup colocava o
  jogo na transação de start — timer disparando com jogo desligado LIGARIA
  o servidor. Fix: `Requires=` removido (o skip offline já existia no
  backup-engine via `is_service_active_or_skip`).
- **CR-06 (P0)**: `NoNewPrivileges=yes` na unit do agente bloqueava o
  `sudo systemctl` do controle remoto (start/stop/restart falhavam em
  silêncio). Fix: `NoNewPrivileges`/`RestrictSUIDSGID` removidos da unit do
  agente (fronteira = sudoers allowlist; demais hardening preservado).
- **CR-07 (P1)**: troca de stack não desativava o `<stack>-backup.timer`
  órfão. Fix: `cleanup_stack_by_type` faz `disable --now` do timer e stop do
  serviço de backup da stack removida.
- **CR-08 (P1)**: rollback de reinstalação APAGAVA artefatos preexistentes
  sem restaurar (e o extra_files do Terraria incluía `Worlds/` — mundos do
  usuário perdidos numa falha de reinstalação!). Fix: snapshot dos artefatos
  antes de sobrescrever + rollback restaurador; contrato novo:
  `stack_rollback_extra_files` nunca lista mundos/mods. Teste novo
  `stack-rollback-test.sh`.
- **CR-09 (P1)**: `reconfigure-hardware` truncava o `server.properties`
  inteiro (RCON, whitelist, level-name, comentários perdidos). Fix: merge —
  bloco gerenciado novo + preservação de tudo que não é chave gerenciada,
  com backup `.crias-bak`. Contrato de merge no `minecraft-tuning-test.sh`.
- **CR-10 (P2)**: `manager_resolve_self` resolvia para a lib
  (manager-common.sh), não para o manager — auto-elevação reinvocava a lib.
  Fix: caller passa `${BASH_SOURCE[0]}` explicitamente.
- **CR-11 (P1)**: bot ficava eternamente esperando o agente conectar antes
  de entrar no Discord (retry infinito no `connect()`). Fix: bot inicia
  primeiro; conexão do agente em task supervisionada; comandos reportam
  agente offline até conectar.
- **CR-12 (P1)**: retorno tModLoader→vanilla no mesmo diretório rodava tML
  para sempre (detecção por artefato legado). Fix: `TERRARIA_USE_TMODLOADER`
  persistido no runtime.env com prioridade sobre a detecção; installer
  vanilla renomeia o marcador legado (não destrutivo).
- **CR-13 (P1)**: backup do Minecraft ignorava `level-name` customizado
  (mundo nunca backupeado). Fix: `BACKUP_DIRS` resolve o mundo efetivo via
  `server.properties`.
- **CR-14 (P1)**: backup não incluía configuração nem mods. Fix: escopo
  ampliado (server.properties, config/, mods/ — opt-out via
  `BACKUP_INCLUDE_MODS=false`); engine aceita arquivos além de diretórios;
  `docs/restore.md` reescrito.
- **CR-15 (P1)**: `BACKUP_REMOTE_PATH`/`BACKUP_NOTIFY_WEBHOOK` do
  `config.env` nunca chegavam ao backup-cron. Fix: propagação
  config.env → stack env → runtime.env, com preservação em
  reconfigure-hardware e rejeição de caracteres que quebrariam o `source`.
- **CR-16 (P1)**: falha de `save-all` era mascarada por `|| true` — tar rodava
  sem flush confirmado. Fix: fail-closed — 2 tentativas, falhou aborta o
  backup com `save-on` restaurado pelo trap.
- **CR-17 (P1)**: bootstrap prosseguia sem verificar SHA256 (sha ausente,
  hash não listado ou sha256sum faltando = warn + continua). Fix:
  fail-closed nos três casos; falha no download do sha256sums.txt também
  aborta. Teste do bootstrap atualizado para o novo contrato.
- **CR-18 (P1)**: binário do agente instalado sem verificar o checksum da
  release. Fix: download do asset `.sha256` da mesma release + verificação
  antes do `install` (binário adulterado não é instalado).
- **CR-19 (P1)**: release podia ser publicada com testes Shell falhos (o job
  `release` só dependia dos builds). Fix: `needs` inclui lint-shell,
  test-shell e test-shell-arch.
- **CR-20 (P2)**: `MINECRAFT_INSTALL_MODPACK=false` era ignorado (modpack
  instalado mesmo assim). Fix: flag honrada — instala só servidor base
  (loader+versão), equivalente a source=vanilla.
- **CR-21 (P1)**: lista QoL podia divergir sem falhar (skip coletivo quando
  mods/ não-vazio + `|| true` nos downloads). Fix: checagem por slug +
  relatório de pendências (QoL e extras) em vez de silêncio.
- **CR-22 (P2)**: mods tML declarados "habilitados" no enabled.json sem os
  `.tmod` em disco (steamcmd ausente ou download falho = sucesso falso).
  Fix: separação intent/installed/enabled — `install.txt` registra o
  pedido; `enabled.json` só com workshop IDs verificados em disco;
  pendências reportadas com comando manual de recovery.
- **CR-23 (P2)**: `StopServer` com timeout montava `systemctl stop
  --timeout=N` — flag inexistente (systemd 257: `unrecognized option`).
  Fix: timeout do cliente vira apenas deadline gRPC; SIGTERM/timeout ficam
  com a unit (`KillSignal`/`TimeoutStopSec`).
- **CR-24 (P2)**: `VIRT_TUNING_BEHAVIOR=force` documentado mas nunca lido (a
  mensagem sugeria `SYSTEM_TUNING_SCOPE`, também não consultado no branch).
  Fix: `force` implementado no `apply_stack_system_tuning` e propagado pelo
  stack env; contrato das duas variáveis documentado em
  `docs/hardware-tuning.md`.
- **CR-25 (P1)**: unit rejeitada pelo `systemd-analyze verify` era instalada
  mesmo assim (warning) e `systemctl enable` era `|| true`. Fix: verificação
  e habilitação bloqueantes (falha = rollback via EXIT trap).
- **CR-26 (P2)**: guia de restore presunha `world_nether/`/`world_the_end/`
  sempre presentes. Fix: `docs/restore.md` manda listar o conteúdo do
  archive e restaurar apenas o que existe (inclui mundos com level-name
  customizado e backups legados só-mundo).
- **CR-27 (P1)**: exemplo nftables com `policy drop` sem `ct state
  established,related`/ICMP podia cortar o acesso SSH do próprio admin.
  Fix: exemplo completo (estado, ICMP/ICMPv6, SSH admin) + aviso de rollback
  temporizado antes de aplicar.
- **CR-28 (P2)**: timeout gRPC de 10s no `/mc stop` perdia a corrida com o
  `TimeoutStopSec=120` da unit. Fix: `STOP_RPC_TIMEOUT=130s` para
  stop/restart no `agent_client.py`.

### Corrigido — Documentação (DOC-01..DOC-10)

- **DOC-01**: bloco de código Markdown não fechado no deploy do
  `discord-bot/README.md`.
- **DOC-02**: links quebrados `mminecraft/README.md` no `docs/tutorial.md`.
- **DOC-03**: CI anunciada como "12 jobs + ISO na release" — são 10 jobs e a
  release não tem ISO.
- **DOC-04**: sincronização de comandos Discord prometida como automática —
  exige `FORCE_SYNC_COMMANDS=true` (agora documentada e no `.env.example`).
- **DOC-05**: URL manual `agent-latest` inexistente →
  `releases/latest/download/...`.
- **DOC-06**: ROADMAP com statuses superestimados — matriz honesta
  implementado/testado; itens de backup remoto/webhook marcados como feitos.
- **DOC-07**: `backup-rcon-failure-test.sh` e `envsubst-test.sh` fora do
  `run-all.sh` e da CI — incluídos, junto com os testes novos (java-flags,
  saveon-success, rollback).
- **DOC-08**: passagem warning do shellcheck documentada como informativa
  (decisão de bloqueio gradativo pendente).
- **DOC-09**: referências a ISO descontinuada esclarecidas (bootstrap,
  docs); nome legacy `MINECRAFT_ADRENALINE_VERSION` documentado no
  `config.env`.
- **DOC-10**: README do agente dizia que o token era impresso — na verdade
  vai para arquivo protegido (0600).

### Adicionado

- `BACKUP_INCLUDE_MODS` (default true) no `config.env`/runtime.env: controla
  se jars de mods entram nos backups (mundos e config sempre entram).
- `env_file_read_value` no `common.sh` (leitura de chave com strip de aspas
  para preservação de config em rewrites de runtime.env).
- `tml_workshop_item_installed` no `tmodloader.sh` (verificação de download
  físico por workshop ID).
- Guards de execução direta (`BASH_SOURCE == $0`) nos `backup-cron.sh` —
  permitem source em testes.


### Corrigido

- **F9-TUI-fix (TUI invisível durante `curl | bash`)**: o `exec </dev/tty
  2>/dev/null` do `crias-bootstrap.sh` matava o stderr do shell inteiro
  (herdado pelo `install.sh`), e o gum renderiza o TUI em stderr
  (`tea.WithOutput(os.Stderr)`) → TUI invisível + espera de input às cegas.
  Fix: subshell guard `if (exec </dev/tty) 2>/dev/null; then exec </dev/tty; fi`.
  `tests/static-audit.sh` ganhou regex contra o padrão `gum ... 2>/dev/null`.
- **Crash `tui.sh: line 142: TUI_THEME_BORDER: unbound variable`**: o commit
  do F9-TUI-fix apagou acidentalmente as 2 definições de `TUI_THEME_*` no
  mesmo hunk em que removia os `2>/dev/null`. Fix: definições restauradas
  (env-overridable, fiéis ao CHANGELOG v1.2.0).
- **Downloads grandes 100% silenciosos**: `_curl_with_retry` suprimia o
  stderr inteiro. Fix: `curl_with_progress` — `gum spin` com título quando há
  TTY no stderr; curl puro (stderr suprimido) em CI. Erros do curl agora
  visíveis em falha.
- **Crash `install.sh: line 620: selected_csv: unbound variable`** (seleção
  de mods tModLoader): `local selected_csv="$default_csv"` DENTRO do
  `tui_checklist` sombreava a var-alvo do caller — o `printf -v "$var_out"`
  escrevia na cópia interna e o caller via "unbound" sob `set -u`. Fix por
  classe: TODAS as internas de `tui_choose`/`tui_input`/`tui_checklist` (e
  `ask_value`) com prefixo `_tui_`/`_av_`; teste fake-gum no
  `tui-fallback-test.sh` falha se o shadowing voltar.
- **Checklist ensinava tecla errada**: o gum 2.x alterna com `x` (não
  ESPAÇO). O header do `tui_checklist` agora diz "(x para marcar, Enter para
  confirmar)".
- **Bug NUL em validações** (2 ocorrências): o padrão `[[ "$x" == *$'\0'* ]]`
  expande para `**` e casa com TUDO — rejeitava QUALQUER valor. Afetava o
  QoL do Minecraft (nenhum mod era instalado em vanilla+fabric; mascarado
  pelo gate mods/-não-vazio) e o `setup-cron.sh` de backup (rejeitava
  qualquer path válido). Braço NUL removido; `*..*`/`*/*` cobrem o traversal
  real.
- **"Mudar stack" do hub era no-op**: `select_server_type` fazia early-return
  com `SERVER_TYPE` setado. Fix: `--force` re-exibe o prompt (com "← Voltar"
  para cancelar).
- **Seleção dinâmica "cancelava" sozinha sem TTY de stdin**: `tui_available`
  checava `[ -t 0 ]`, mas o `tui_filter` SEMPRE recebe a lista por pipe →
  fallback lia EOF. Fix: gate por `[ -t 2 ]` + fallback lê de `/dev/tty`.
- **Códigos ANSI crus na tela**: variáveis de cor em `common.sh` eram
  strings literais `"\033[...m"` usadas com `printf '%s'`. Fix: `$'...'`
  com byte ESC real (53+ usos).
- **Resumo mostrava paths do Minecraft ao instalar Terraria**: default de
  `MINECRAFT_SERVER_DIR` sempre setado vencia o `:-`. Fix: resumo por stack.
- **Versão do modpack personalizado era ignorada** (auditoria de modpacks):
  o wizard guardava a versão escolhida (top-10/busca/slug) em
  `MINECRAFT_ADRENALINE_VERSION`, mas o installer chamava
  `mrpack-install <slug>` SEM a versão no `source=modrinth` — instalava
  sempre a mais recente. Fix: versão passada como argumento posicional
  (como a doc sempre prometeu).
- **Prompt enganoso "trocar loader para fabric?" com default Y para modpacks
  genéricos**: o aviso (herdado da era Adrenaline-only) sugeria trocar o
  loader para fabric com default Y mesmo quando o usuário escolheu um
  modpack forge/neoforge/quilt — confirmar quebraria a instalação. Fix: o
  prompt só aparece para `MINECRAFT_MODPACK_SOURCE=adrenaline`; modpacks
  genéricos já vêm filtrados por compatibilidade (server-side na API).
- **Pré-seleção do gum anulada por rótulo com vírgulas**: `gum choose
  --selected` interpreta CSV; o default "Catálogo curado (Calamity, Thorium,
  etc.)" nunca casava e o cursor caía no "← Voltar" (Enter às cegas voltava
  sem querer). Fix: rótulo renomeado sem vírgulas + `tui_choose` não passa
  `--selected` quando o default contém vírgula (defesa para o futuro).
- **Server icon configurado no wizard nunca era baixado**:
  `MINECRAFT_SERVER_ICON_URL` não era exportado no stack env file →
  `download_server_icon_if_set` via a var vazia. Fix: exportada no
  `write_stack_env_file`.

### Adicionado

- **Mods individuais por cima do modpack** (`MINECRAFT_EXTRA_MODS`, CSV de
  slugs Modrinth): wizard pergunta após o QoL, config.env, resumo e hook
  `stack_install_extra_mods` no framework — NÃO pula quando `mods/` já tem
  arquivos do modpack (esse é o ponto), idempotente por `${slug}.jar`,
  `|| true` para um mod que falhar não derrubar o installer.
- **Títulos de etapa + clear + navegação "← Voltar"** no wizard:
  `tui_clear`/`tui_stage` nas 5 etapas; "← Voltar" funcional em
  loader/versão/fonte do modpack/tModLoader (sai da etapa preservando
  escolhas, volta ao hub); sub-flows top-10/busca/slug voltam ao menu de
  fonte em vez de matar o script; ajuda como opção ("? Ajuda") em vez de
  automática.
- **Validação dos Workshop IDs manuais (tModLoader)**: CSV numérico com
  re-prompt (antes, lixo só falhava depois, silenciosamente, no steamcmd).
- **Caso de teste do passo 4 (fallback) do `mc_suggest_closest_version`**
  (`2.0.0` → major ausente): fecha o gap M4 do mutation-test — a M4 também
  tinha o pattern quebrado (o `\n` literal do `printf '%s\n'` virava newline
  no python do `run_mutation` → "pattern nao casou" para sempre).

### Mudado

- **Pacotes atualizados** (auditoria 2026-11):
  - `MRPACK_INSTALL_VERSION` `v0.21.0-beta` → `v0.23.0` (primeira stable;
    downloads staged; `--server-file` para todo loader; servers
    Forge/NeoForge; CLI `<pack> [versão]` inalterada; asset `.pkg.tar.zst`
    no mesmo padrão de URL).
  - `TERRARIA_DOWNLOAD_URL` `terraria-server-1456.zip` → `terraria-server-1458.zip`
    (1459+ = 404 no terraria.org; auditado 2026-11).
  - `MINECRAFT_VERSION` default `1.21.11` → `26.3` (release atual do
    manifest Mojang; alinhado com o Adrenaline `26.5.1+mc26.3` e com os mods
    QoL, que já publicam builds `26.3`; o default `1.21.11` instalava
    modpack 26.3 + QoL 1.21.11 misturados em NON_INTERACTIVE).
  - User-Agent das APIs `crias-server-installer/1.2.0` → `1.3.0`.
- **Resumo da instalação**: mostra a versão do modpack (ou "mais recente") e
  "nenhum (vanilla, so loader)" quando aplicável.
- Comentários stale "tModLoader WIP — não implementado" corrigidos
  (implementado desde v1.2.1).

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
