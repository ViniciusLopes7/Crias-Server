# Interface TUI (Terminal User Interface)

O Crias-Server utiliza menus de terminal no instalador e um **hub de gerenciamento** independente (`crias-tui`). Este documento distingue as duas interfaces, seus requisitos e as opções de recuperação.

Para visão geral, veja o [README principal](../README.md). Para o seletor de
modpacks, veja [minecraft/modpacks.md](minecraft/modpacks.md).

## Como funciona

O `install.sh` carrega a biblioteca [`shared/lib/tui.sh`](../shared/lib/tui.sh),
que expõe funções de alto nível (`tui_choose`, `tui_filter`, `tui_confirm`,
`tui_input`, `tui_checklist`, `tui_msg`). Cada função:

1. Detecta se `gum` está instalado **e** stdin é um TTY (`tui_available`).
2. Se sim, delega para o subcomando correspondente do `gum`.
3. Se não, cai automaticamente para o prompt `read` clássico (com as cores e
   formatação de `common.sh`).

```
┌─────────────────────────────────────────────────────────────┐
│  install.sh (main)                                          │
│    ├─ select_server_type     → tui_choose (menu)             │
│    ├─ prompt_global_options  → tui_confirm + tui_input       │
│    └─ prompt_minecraft_options                                │
│         ├─ loader: tui_choose (fabric/quilt/vanilla/forge/neoforge)
│         ├─ versão MC: tui_filter (busca fuzzy nos manifests) │
│         ├─ modpack:  tui_choose (fonte) → tui_filter (busca)  │
│         └─ QoL:     tui_confirm                               │
└─────────────────────────────────────────────────────────────┘
```

## Instalador e hub: diferenças

- **Instalador (`install.sh`):** perguntas de configuração, seleção de modpack e implantação dos serviços; usa a biblioteca `shared/lib/tui.sh`.
- **Hub (`sudo crias-tui`):** operações de servidor, monitoramento e backup; oferece menu numerado sem `gum` e diagnóstico de somente leitura (`--doctor`).

## Requisitos

| Componente | Onde | Necessário? |
|------------|------|-------------|
| `gum` | `extra/gum` (Arch official) | Sim, para TUI rica. Sem ele, o instalador cai no fallback `read`. |
| `jq` | `extra/jq` | Sim, para parsing de manifests (Mojang/Fabric/Modrinth). |
| `curl` | `core/curl` | Sim, para buscar versões/modpacks nas APIs. |
| TTY | stdin interativo | Sim, para `gum` renderizar. Em CI (`NON_INTERACTIVE=true`), o TUI não é usado. |

Para instalar o gum: `sudo pacman -S gum` (não vem no Arch base).

## Comportamento de fallback

Se `gum` não estiver disponível (ex.: instalando em Arch Linux limpo sem a
ISO, ou em um container CI), **todas** as funções TUI caem para o caminho
`read`-based:

| Função TUI | Com `gum` | Sem `gum` (fallback) |
|------------|-----------|----------------------|
| `tui_choose` | `gum choose --header=...` | menu numerado (`1) opt`, `2) opt`...) + `read` |
| `tui_filter` | `gum filter --header=...` (busca fuzzy) | menu numerado sem fuzzy |
| `tui_confirm` | `gum confirm --default=...` | `read -p "[Y/n]"` com cores |
| `tui_input` | `gum input --value=... --header=...` | `read -p "[default]:"` (via `ask_value`) |
| `tui_checklist` | `gum choose --no-limit --selected=...` | toggle por número até Enter |
| `tui_msg` | `gum style --border=normal` | `printf` + `read` para ack |

### EOF / cancelamento

Em todos os casos, se stdin chegar ao EOF (sem input — comum em CI/redirecionamento):

- `tui_choose` / `tui_input` / `tui_checklist`: **honram o default** passado
  pelo caller (paridade entre os dois caminhos).
- `tui_confirm`: honra o default (`Y` → retorna 0/yes, `N` → retorna 1/no).
- `tui_filter`: retorna **não-zero** (cancelado) — callers tratam como "usar
  default".

Isso garante que scripts não-interativos (`NON_INTERACTIVE=true`) e pipelines
de CI nunca travam esperando input.

## Modo não-interativo

Em `NON_INTERACTIVE=true`, **nenhuma função TUI é chamada** — o `install.sh`
verifica `is_true "$NON_INTERACTIVE"` antes de cada bloco de prompt e pula
direto para os defaults do `config.env` / variáveis de ambiente. Isso é o que
roda em CI (ver [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)).

## Atalhos do gum (referência rápida)

Durante a seleção fuzzy (`gum filter`):

| Tecla | Ação |
|-------|------|
| Setas ↑↓ | Navegar |
| Digitar | Filtrar (fuzzy match) |
| Enter | Confirmar seleção |
| Ctrl+C / Esc | Cancelar (usa default) |

Durante `gum choose` (menu simples):

| Tecla | Ação |
|-------|------|
| Setas ↑↓ / j/k | Navegar |
| Enter | Confirmar |
| Esc | Cancelar |

## Testando o TUI

```bash
# Self-test do módulo (valida o caminho fallback sem gum):
bash shared/lib/tui.sh selftest

# Teste de cobertura (caminho fallback):
bash tests/tui-fallback-test.sh

# Hub: navegação de memória Java e Chunky por entrada real no menu numerado,
# com chamadas administrativas simuladas (não altera servidor nem arquivos).
bash tests/hub-memory-menu-test.sh

# Atalhos Arquivos do Hub: Minecraft/Terraria, erro e confirmacoes;
# o sudo é simulado, e nenhum arquivo real do servidor é modificado.
bash tests/hub-files-menu-test.sh

# Restrições reais dos diretórios e usuário do jogo pelo manager (PTY):
bash tests/hub-files-test.sh

# Hub Voice Chat: menu numerado e Gum input via pseudo-TTY, com sudo simulado:
bash tests/hub-voicechat-menu-test.sh

# Proteções de porta, symlink, configuração e TTY no gerenciador:
bash tests/minecraft-voicechat-test.sh
```

O caminho do **Hub** com Gum e TTY é exercitado em testes automatizados com pseudo-TTY (`tests/hub-gum-test.sh`), inclusive com stdout capturado. Isso não substitui revisão visual e teste com SSH real. A biblioteca de interface do **instalador** mantém testes próprios de fallback (`tests/tui-fallback-test.sh`). O Hub oferece menu numerado quando não há Gum ou terminal adequado.

## Veja também

- [tutorial.md](tutorial.md) — fluxo completo de instalação com TUI.
- [minecraft/modpacks.md](minecraft/modpacks.md) — seletor de modpacks.
- [security.md](security.md) — configuração de SSH.
- [`shared/lib/tui.sh`](../shared/lib/tui.sh) — código-fonte da biblioteca.

## Hub de gerenciamento e recuperação

O submenu **Voice Chat (Minecraft)** agora tem um controlador de interface `hub_minecraft_voicechat_menu()`, no próprio `crias-tui.sh`. São mantidos status, edição da configuração, porta UDP, orientações de Tailscale/firewall e voltar. O Hub continua encaminhando `voicechat status|edit|set-port|network` ao gerenciador, sem validar ou gravar diretamente a configuração. As verificações de faixa da porta, colisão com a porta do jogo, TTY e symlinks permanecem em `minecraft/voicechat-tools.sh` e seus testes. Não há opção Voice Chat para Terraria. Cancelar no menu ou no `gum input` não solicita mudanças.

O menu principal **Arquivos** utiliza o controlador de interface `hub_files_menu()`, mantido no próprio `crias-tui.sh`. Os atalhos **Pasta principal, Mundo, Mods, Configurações, Backups e Logs** continuam delegados ao `mc-manager.sh` ou `tt-manager.sh`. O gerenciador, e não o Hub, verifica os diretórios, as permissões e a execução como usuário do jogo. A instalação opcional do gerenciador de arquivos `mc` continua exigindo confirmação explícita; cancelar ou voltar não executa ações.

O submenu **Servidor → Memória Java (Xms/Xmx)** mantém as mesmas opções e comandos (`memory status`, `memory fixed`, `memory set`, `memory auto`), mas agora tem um controlador de interface próprio (`hub_minecraft_memory_menu`). O `crias-tui.sh:main()` apenas delega a escolha; o gerenciador Minecraft continua responsável por validar valores, gravar configuração e manter as proteções do systemd. Cancelar, voltar ou digitar um valor inválido não deve alterar o heap nem reiniciar o servidor.

O executável `/usr/local/bin/crias-tui` é implantado **antes** da seleção dos jogos, dos downloads e da instalação de serviços. Isso mantém o diagnóstico acessível se a instalação falhar depois dessa etapa.

```bash
sudo crias-tui
sudo crias-tui --doctor  # somente leitura: RAM/swap, estado systemd e OOM
sudo /opt/crias-server/install.sh  # retomar instalador após diagnosticar
```

O hub funciona também sem `gum`, com menu numerado. Se não houver stack detectado, mostra o diagnóstico, em vez de falhar silenciosamente. A ausência do arquivo `crias-tui.sh` ou um erro ao copiá-lo agora interrompe a instalação com mensagem explícita.

Para conferir o bootstrap versionado, **não use** `find /opt/crias-server` sem `-L`: a pasta pode ser um link simbólico. Use `readlink -f /opt/crias-server` e `ls -l /opt/crias-server/crias-tui.sh`.

### Logs do Minecraft pelo hub

No menu **Servidor → Logs**, o Minecraft oferece quatro visões:

| Opção | Resultado |
|---|---|
| Recentes (150 linhas) | Histórico completo com timestamps, sem acompanhar novos eventos |
| Avisos e erros | Filtro textual de mensagens `WARN`, `ERROR`, exceções e OOM das últimas 400 linhas |
| Boot atual | Últimas 200 mensagens registradas desde o boot do Linux |
| Acompanhar ao vivo | Exibe novas mensagens continuamente; interrompa com Ctrl+C |

O filtro de avisos é apenas um atalho: ele não transforma qualquer `WARN` em falha fatal, nem detecta todas as causas de travamento. Para investigar, leia também as mensagens anteriores com **Recentes**. Fora do hub, os mesmos modos estão disponíveis em `sudo /usr/local/libexec/crias/mc-manager.sh logs [follow|recent|boot|alerts]`.
