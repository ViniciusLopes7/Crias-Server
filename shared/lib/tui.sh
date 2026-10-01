#!/bin/bash
# shared/lib/tui.sh
#
# Biblioteca de interface TUI (Terminal User Interface) para o instalador
# Crias-Server. Implementa prompts interativos usando `gum` (Charm) quando
# disponível, com fallback automático para os prompts `read` clássicos
# (ask_value/ask_confirm definidos em common.sh) quando `gum` não está
# instalado (ex.: instalando em Arch limpo sem a ISO, ou em CI).
#
# Design:
#   - Todas as funções usam a sintaxe `printf -v` para atribuir a variáveis
#     nomeadas pelo caller (igual ao ask_value), OU retornam strings no stdout
#     para captura via $(...).
#   - Funções tui_* são "high-level": recebem listas/defaults e produzem seleção.
#   - Funções _tui_gum_* são wrappers internos que chamam gum; se gum ausente
#     ou falhar (exit != 0), caem para o fallback read-based.
#   - Em NON_INTERACTIVE=true, as funções NÃO devem ser chamadas; callers
#     devem checar is_true "$NON_INTERACTIVE" antes. Ainda assim, por segurança,
#     estas funções honram defaults quando stdin não é TTY.
#
# Requisitos do gum (https://github.com/charmbracelet/gum):
#   gum choose  — menu de seleção única (printa escolhido no stdout)
#   gum filter  — busca fuzzy em lista (printa escolhido no stdout)
#   gum confirm — yes/no (exit 0=yes, 1=no)
#   gum input   — entrada de texto livre (printa no stdout)
#   gum style   — formatação de texto (cores, bordas)
#
# Não use emojis nos arquivos; este arquivo segue a convenção do projeto.

# ---------------------------------------------------------------------------
# Detecção de disponibilidade do gum.
# ---------------------------------------------------------------------------

# Retorna 0 se gum está instalado E stdin é um TTY interativo.
# Caso contrário (sem gum, ou stdin pipe), retorna 1 — callers usam fallback.
tui_available() {
    if ! command -v gum >/dev/null 2>&1; then
        return 1
    fi
    # gum precisa de um TTY para renderizar. Se stdin não for TTY
    # (CI, pipe, NON_INTERACTIVE), cai no fallback.
    if [ -t 0 ]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Theming centralizado. Override via env vars para customização sem código.
# gum color codes: 0-255 (216-cube + grayscale). 212 = cyan-ish, default.
# ---------------------------------------------------------------------------
TUI_THEME_COLOR="${TUI_THEME_COLOR:-212}"
TUI_THEME_BORDER="${TUI_THEME_BORDER:-normal}"

# ---------------------------------------------------------------------------
# Mini-wiki: help contextual por tópico, acessível via tui_help <topic>.
# Conteúdo resumido dos docs relevantes. Callers chamam antes de prompts
# complexos (ex.: antes do prompt de tier, chama tui_help "hardware-tier").
# No gum: exibe com gum style (borda + cor). No fallback: print + read ack.
# ---------------------------------------------------------------------------
tui_help() {
    local topic="$1"
    local body=""
    case "$topic" in
        hardware-tier)
            body="Tiers LOW/MID/HIGH baseados em RAM/CPU/disco.
LOW: ≤3GB RAM ou ≤2 cores. MID: ≤12GB ou ≤6 cores. HIGH: >12GB e >6 cores.
Afeta: heap JVM, max-players, view-distance, MemoryMax systemd, retenção backup.
Override: FORCE_HARDWARE_TIER em config.env (vazio=auto)."
            ;;
        loader)
            body="Loaders suportados: fabric | quilt | vanilla | forge | neoforge.
fabric: padrão, compatível com modpacks .mrpack do Modrinth.
quilt: compatível com a maioria dos mods Fabric.
vanilla: server.jar oficial, sem mods.
forge/neoforge: para mods Forge (mrpack-install suporta).
paper removido em v1.2.0 (sem fluxo .mrpack)."
            ;;
        modpack)
            body="Fontes: Top-10 Modrinth | Busca por nome | Vanilla (só loader) | Slug manual.
Compatibilidade validada server-side (loader + versão MC).
Se incompatível: sugere versão MC mais próxima e pergunta se troca."
            ;;
        online-mode)
            body="online-mode=true (premium): exige conta Mojang, seguro.
online-mode=false (offline): qualquer um entra com qualquer nick.
NUNCA use false em servidor exposto à internet."
            ;;
        tailscale)
            body="Tailscale: VPN mesh (tailnet). Instala tailscaled + ativa.
'sudo tailscale up' para autenticar.
'sudo tailscale funnel 8473' expõe o crias-agent via HTTPS público
(para o bot Discord no Railway conectar sem estar na VPN)."
            ;;
        system-tuning)
            body="Tuning de host: zram (swap em RAM), sysctl (swappiness/vfs_cache),
I/O scheduler (bfq HDD / mq-deadline SSD), cpupower governor.
Pulado automaticamente em container/VPS (VIRT_TUNING_BEHAVIOR=auto).
Force com VIRT_TUNING_BEHAVIOR=force (não recomendado)."
            ;;
        cleanup)
            body="Cleanup do stack oposto (não-destrutivo):
- systemctl stop + disable do stack oposto
- remove autoload de aliases
- remove entradas de crontab de backup
PRESERVA: dados em /opt/, usuários, backups existentes."
            ;;
        ssh)
            body="SSH no host instalado (INSTALL_SSH=true):
- instala openssh + habilita sshd.service
- cria usuário 'crias' (grupo wheel = sudo, senha pedida)
- PermitRootLogin no (root proibido via SSH)
Conexão: ssh crias@<ip> (use a senha definida)."
            ;;
        agent)
            body="crias-agent: binário Go (gRPC em localhost:8473).
Controle remoto via Discord bot (discord.py 2.x no Railway).
Slash commands: /mc start|stop|restart|status|players|say|console|health.
Token auto-gerado em /etc/crias/agent.yaml (chmod 0640).
Expõe via Tailscale Funnel: sudo tailscale funnel 8473."
            ;;
        monitor)
            body="Ferramentas de monitoramento (subcomando 'monitor'):
- monitor (ou monitor cpu): btop (fallback htop) — CPU/RAM/processos
- monitor disk: ncdu — explorador de uso de disco interativo
- monitor net: btop tem aba de network (ou iotop-c para I/O por processo)
Disponível na ISO Crias-Server (pré-instalado)."
            ;;
        *)
            body="Ajuda não disponível para o tópico: $topic"
            ;;
    esac

    if tui_available; then
        gum style --border="$TUI_THEME_BORDER" --padding="1 2" --foreground="$TUI_THEME_COLOR" \
            -- "Ajuda: $topic" "" "$body" 2>/dev/null || true
        gum confirm --default=yes -- "Continuar?" 2>/dev/null || true
    else
        print_prompt "Ajuda: $topic"
        printf '  %s\n' "$body"
        read -r -p "$(printf '%b' "${CYAN}  ➜ [Enter] para continuar: ${NC}")" _answer || true
    fi
    return 0
}

# User-Agent / identificação consistente (gum não usa, mas mantemos para
# referência caso logs precisem identificar origem do TUI).
_tui_engine() {
    if tui_available; then
        echo "gum"
    else
        echo "read"
    fi
}

# ---------------------------------------------------------------------------
# Seleção única de menu.
# Uso: tui_choose "var_out" "prompt" "default" "opcao1" "opcao2" ...
# Atribui a var_out a opção escolhida (ou default se input vazio/invalido).
# Retorna 0 sempre (EOF, input invalido, ou cancel no gum usam o default;
# para não travar fluxos que esperam um valor). Em caso de input invalido,
# emite print_warning antes de usar o default.
# ---------------------------------------------------------------------------
tui_choose() {
    local var_out="$1"
    local prompt="$2"
    local default="$3"
    shift 3
    local options=("$@")

    if tui_available; then
        local choice
        # --header mostra o prompt; --selected pré-seleciona o default se
        # ele estiver na lista (gum erro se o valor não estiver nas options).
        local selected_args=()
        local opt
        for opt in "${options[@]}"; do
            if [ "$opt" = "$default" ]; then
                selected_args=(--selected="$default")
                break
            fi
        done
        # gum choose printa a opção escolhida no stdout; exit 0=ok, 130=cancel.
        if choice=$(gum choose \
                --header="$prompt" \
                --height="${#options[@]}" \
                "${selected_args[@]}" \
                "${options[@]}" 2>/dev/null); then
            printf -v "$var_out" '%s' "$choice"
            return 0
        fi
        # Cancelado (Esc/Ctrl+C) — usa default e sinaliza não-cancelado para
        # manter paridade com ask_value (que usa default em EOF). Caller pode
        # checar retorno se quiser distinguir. Aqui retornamos 0 com default
        # para não travar fluxos que esperam um valor.
        printf -v "$var_out" '%s' "$default"
        return 0
    fi

    # Fallback read-based: enumera opções numeradas.
    print_prompt "$prompt"
    local i=1
    local opt
    for opt in "${options[@]}"; do
        # Marca o default com [*].
        if [ "$opt" = "$default" ]; then
            printf '  %s[*] %s\n' "$i" "$opt"
        else
            printf '  %s) %s\n' "$i" "$opt"
        fi
        i=$((i + 1))
    done
    local answer
    if ! read -r -p "$(printf '%b' "${CYAN}  ➜ [${default}]: ${NC}")" answer; then
        # EOF/SIGINT: usa default (consistente com ask_value).
        printf -v "$var_out" '%s' "$default"
        return 0
    fi
    if [ -z "$answer" ]; then
        printf -v "$var_out" '%s' "$default"
        return 0
    fi
    # Se digitou número, resolve via índice; valida que está na faixa.
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
        printf -v "$var_out" '%s' "${options[$((answer - 1))]}"
        return 0
    fi
    # Se digitou texto, valida que corresponde a uma das opções (match exato).
    local opt
    for opt in "${options[@]}"; do
        if [ "$opt" = "$answer" ]; then
            printf -v "$var_out" '%s' "$answer"
            return 0
        fi
    done
    # Input invalido (numero fora da faixa ou texto nao-listado): usa default.
    print_warning "Opcao invalida: '$answer'. Usando default: '$default'"
    printf -v "$var_out" '%s' "$default"
    return 0
}

# ---------------------------------------------------------------------------
# Seleção única com busca fuzzy (via gum filter; fallback sem fuzzy).
# Recebe linhas no stdin (uma por linha). Printa a escolhida no stdout.
# Uso: choice=$(tui_filter "prompt" < <(printf '%s\n' "${items[@]}"))
# Retorna 0 em sucesso (printa escolha no stdout), 1 se cancelado/sem seleção.
# Em fallback, mostra menu numerado sem fuzzy.
# ---------------------------------------------------------------------------
tui_filter() {
    local prompt="$1"
    local lines
    # Lê stdin inteiro para poder re-usar tanto no gum quanto no fallback.
    lines=$(cat)

    if [ -z "$lines" ]; then
        return 1
    fi

    if tui_available; then
        # gum filter: busca fuzzy interativa. --header mostra o prompt.
        # --height auto. Printa selecionado no stdout.
        local choice
        if choice=$(printf '%s\n' "$lines" | gum filter --header="$prompt" 2>/dev/null) && [ -n "$choice" ]; then
            printf '%s\n' "$choice"
            return 0
        fi
        return 1
    fi

    # Fallback: menu numerado (sem fuzzy). Útil para listas pequenas.
    print_prompt "$prompt"
    # Mapa para resolver índice->linha (preserva linhas com espaços).
    local -a arr=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && arr+=("$line")
    done <<< "$lines"

    if [ "${#arr[@]}" -eq 0 ]; then
        return 1
    fi

    local i=1
    for line in "${arr[@]}"; do
        printf '  %s) %s\n' "$i" "$line"
        i=$((i + 1))
    done
    local answer
    if ! read -r -p "$(printf '%b' "${CYAN}  ➜ numero: ${NC}")" answer; then
        return 1
    fi
    if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#arr[@]}" ]; then
        printf '%s\n' "${arr[$((answer - 1))]}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Yes/No com TUI.
# Uso: tui_confirm "prompt?" "Y"  -> retorna 0=yes, 1=no (igual ask_confirm).
# ---------------------------------------------------------------------------
tui_confirm() {
    local prompt="$1"
    local default_ans="${2:-Y}"

    if tui_available; then
        # gum confirm: --default=yes/no. Exit 0=yes, 1=no, 130=cancel(=no).
        local gum_default="no"
        if [ "${default_ans^^}" = "Y" ]; then
            gum_default="yes"
        fi
        if gum confirm --default="$gum_default" -- "$prompt" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    # Fallback: delega para ask_confirm (common.sh) que já usa read + cores.
    # ask_confirm trata EOF como cancelamento (return 1) mesmo com default Y.
    # Para paridade com tui_input/tui_choose (que honram default em EOF), fazemos
    # um read explicito e honramos o default se stdin for EOF.
    print_prompt "$prompt"
    local prompt_text
    if [ "${default_ans^^}" = "Y" ]; then
        prompt_text="${CYAN}  ➜ [Y/n]: ${NC}"
    else
        prompt_text="${CYAN}  ➜ [y/N]: ${NC}"
    fi
    local answer
    if ! read -r -p "$(printf '%b' "$prompt_text")" answer; then
        # EOF/SIGINT: honra o default (paridade com tui_input/tui_choose).
        if [ "${default_ans^^}" = "Y" ]; then
            return 0
        fi
        return 1
    fi
    if [ -z "$answer" ]; then
        answer="$default_ans"
    fi
    if [[ "${answer^^}" == "Y" || "${answer^^}" == "YES" || "${answer^^}" == "S" || "${answer^^}" == "SIM" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Entrada de texto livre.
# Uso: tui_input "var_out" "prompt" "default" -> atribui a var_out.
# Retorna 0 sempre (EOF usa default, paridade com ask_value).
# ---------------------------------------------------------------------------
tui_input() {
    local var_out="$1"
    local prompt="$2"
    local default="$3"

    if tui_available; then
        # gum input: --placeholder, --value (pré-preenchido), --prompt.
        # --value já vem como default editável; --char-limit=0 = sem limite.
        local value
        if value=$(gum input --header="$prompt" --value="$default" --char-limit=0 2>/dev/null) && [ -n "$value" ]; then
            printf -v "$var_out" '%s' "$value"
            return 0
        fi
        # Cancelado ou vazio: usa default.
        printf -v "$var_out" '%s' "$default"
        return 0
    fi

    # Fallback: ask_value (common.sh). ask_value não atribui em EOF (read falha),
    # então pré-setamos a var com default e deixamos ask_value sobrescrever
    # apenas se o usuário digitar algo.
    printf -v "$var_out" '%s' "$default"
    ask_value "$prompt" "$default" "$var_out" || true
}

# ---------------------------------------------------------------------------
# Multi-seleção (checklist).
# Uso: tui_checklist "var_out" "prompt" "default_csv" "opt1" "opt2" ...
# default_csv = lista separada por vírgula das opções pré-marcadas.
# Atribui a var_out CSV das selecionadas (vazio se nenhuma).
# Retorna 0 em sucesso.
# ---------------------------------------------------------------------------
tui_checklist() {
    local var_out="$1"
    local prompt="$2"
    local default_csv="$3"
    shift 3
    local options=("$@")

    # Valida default_csv contra options (defesa contra injection).
    local -A default_set=()
    local d
    local IFS=','
    for d in $default_csv; do
        # trim whitespace
        d="${d#"${d%%[![:space:]]*}"}"
        d="${d%"${d##*[![:space:]]}"}"
        [ -n "$d" ] && default_set["$d"]=1
    done
    unset IFS

    if tui_available; then
        # gum choose --no-limit permite multi-seleção. Pré-seleciona via --selected
        # (CSV). Printa cada selecionado em uma linha.
        local selected_csv="$default_csv"
        local raw
        if raw=$(gum choose --no-limit --header="$prompt" --selected="$default_csv" \
                --height=$(( ${#options[@]} + 2 )) \
                "${options[@]}" 2>/dev/null); then
            # gum printa uma opção por linha; junta em CSV.
            selected_csv=""
            local first=1
            local sel
            while IFS= read -r sel; do
                [ -z "$sel" ] && continue
                if [ "$first" -eq 1 ]; then
                    selected_csv="$sel"
                    first=0
                else
                    selected_csv="$selected_csv,$sel"
                fi
            done <<< "$raw"
            printf -v "$var_out" '%s' "$selected_csv"
            return 0
        fi
        printf -v "$var_out" '%s' "$default_csv"
        return 0
    fi

    # Fallback: toggle por número até Enter vazio.
    print_prompt "$prompt"
    local -A chosen=()
    local opt
    for opt in "${!default_set[@]}"; do
        chosen["$opt"]=1
    done
    while true; do
        local i=1
        for opt in "${options[@]}"; do
            local mark=" "
            if [ -n "${chosen[$opt]:-}" ]; then
                mark="[x]"
            else
                mark="[ ]"
            fi
            printf '  %s) %s %s\n' "$i" "$mark" "$opt"
            i=$((i + 1))
        done
        printf '  0) confirmar\n'
        local answer
        if ! read -r -p "$(printf '%b' "${CYAN}  ➜ toggle (0=ok): ${NC}")" answer; then
            break
        fi
        if [ "$answer" = "0" ] || [ -z "$answer" ]; then
            break
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "${#options[@]}" ]; then
            opt="${options[$((answer - 1))]}"
            if [ -n "${chosen[$opt]:-}" ]; then
                unset 'chosen[$opt]'
            else
                chosen["$opt"]=1
            fi
        fi
    done
    local result=""
    local first=1
    for opt in "${options[@]}"; do
        if [ -n "${chosen[$opt]:-}" ]; then
            if [ "$first" -eq 1 ]; then
                result="$opt"
                first=0
            else
                result="$result,$opt"
            fi
        fi
    done
    printf -v "$var_out" '%s' "$result"
    return 0
}

# ---------------------------------------------------------------------------
# Mensagem informativa (pausa até ack).
# Uso: tui_msg "titulo" "corpo"
# ---------------------------------------------------------------------------
tui_msg() {
    local title="$1"
    shift
    local body="$*"

    if tui_available; then
        # gum style formata com borda; theming centralizado em TUI_THEME_*.
        gum style --border="$TUI_THEME_BORDER" --padding="1 2" --foreground="$TUI_THEME_COLOR" \
            -- "$title" "" "$body" 2>/dev/null || true
        # Pausa até Enter (gum não tem msgbox puro; confirm --default=yes funciona).
        gum confirm --default=yes -- "Continuar?" 2>/dev/null || true
        return 0
    fi

    print_prompt "$title"
    printf '  %s\n' "$body"
    read -r -p "$(printf '%b' "${CYAN}  ➜ [Enter] para continuar: ${NC}")" _answer || true
    return 0
}

# ---------------------------------------------------------------------------
# Auto-teste (executável standalone): confirma que o módulo carrega e que o
# fallback funciona sem gum. Não testa o caminho gum (precisa de TTY).
# ---------------------------------------------------------------------------
_tui_selftest() {
    echo "[tui] engine detectado: $(_tui_engine)"
    echo "[tui] tui_available: $(tui_available && echo yes || echo no)"

    # Smoke test do fallback read-based:
    # tui_choose usa printf (print_prompt) no stdout; o valor atribuido vai
    # para a var nomeada. Isolamos o stdout do prompt mandando-o para stderr
    # dentro do subshell, e capturamos só o echo final da var.
    local result=""
    # shellcheck disable=SC2154  # r é atribuída via printf -v dentro de tui_choose
    result=$(printf '' | { tui_choose r "Teste" "alpha" "alpha" "beta" "gamma" >&2; echo "$r"; } 2>/dev/null || true)
    if [ "$result" = "alpha" ]; then
        echo "[tui] selftest choose-fallback: OK (default retornado em EOF)"
    else
        echo "[tui] selftest choose-fallback: FAIL (result='$result')" >&2
        return 1
    fi

    # Smoke test do tui_confirm fallback em EOF: default N -> retorna 1 (no).
    local rc=0
    printf '' | tui_confirm "Confirma?" "N" >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 1 ]; then
        echo "[tui] selftest confirm-fallback (default N): OK (retornou no)"
    else
        echo "[tui] selftest confirm-fallback (default N): FAIL (rc=$rc)" >&2
        return 1
    fi

    # Smoke test do tui_input fallback em EOF: atribui default.
    # Importante: NÃO usar pipe (lado direito roda em subshell e a atribuição
    # não propaga). Usamos redirecionamento de stdin no shell corrente.
    local val=""
    tui_input val "Prompt" "meu-default" </dev/null >/dev/null 2>&1 || true
    if [ "$val" = "meu-default" ]; then
        echo "[tui] selftest input-fallback: OK (default retornado em EOF)"
    else
        echo "[tui] selftest input-fallback: FAIL (val='$val')" >&2
        return 1
    fi

    return 0
}

# Permite rodar como script para self-test: bash shared/lib/tui.sh selftest
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Carrega dependências (common.sh) para o self-test ter ask_confirm/ask_value.
    # BASH_SOURCE aponta para shared/lib/tui.sh; precisamos subir 2 níveis.
    _tui_self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    # shellcheck source=/dev/null
    source "$_tui_self_root/shared/lib/common.sh" 2>/dev/null || true
    unset _tui_self_root
    case "${1:-}" in
        selftest) _tui_selftest ;;
        *)
            echo "Uso: source este arquivo OU rode 'bash $0 selftest'"
            echo "Engine atual: $(_tui_engine)"
            ;;
    esac
fi
