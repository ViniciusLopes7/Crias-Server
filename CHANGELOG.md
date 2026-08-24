# Changelog

Todos os mudanças notáveis do projeto Crias-Server serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e o projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

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
