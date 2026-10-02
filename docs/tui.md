# Interface TUI (Terminal User Interface)

Desde a v1.2.0, o instalador Crias-Server usa uma **TUI** baseada em `gum`
(Charm) para todos os prompts interativos. Este documento descreve como ela
funciona, os requisitos, e o comportamento de fallback.

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
```

O caminho `gum` (com TTY) é exercitado manualmente, não em CI.

## Veja também

- [tutorial.md](tutorial.md) — fluxo completo de instalação com TUI.
- [minecraft/modpacks.md](minecraft/modpacks.md) — seletor de modpacks.
- [security.md](security.md) — configuração de SSH.
- [`shared/lib/tui.sh`](../shared/lib/tui.sh) — código-fonte da biblioteca.
