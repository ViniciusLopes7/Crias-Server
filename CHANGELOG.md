# Changelog

Todos os mudanças notáveis do projeto Crias-Server serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

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
