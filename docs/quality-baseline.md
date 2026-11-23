# Linha de base de qualidade — 2026-11-23

**Referência imutável:** `main@9496a5f04e3c2f093926f21f69b38251c11af8fe`, anterior ao PR de política. Objetivo: permitir comparar mudanças futuras sem confundir aumento de testes/documentação com inchaço de produção.

## Inventário inicial (GitHub tree)

| Medida | Valor | Método/limite |
|---|---:|---|
| Arquivos versionados | 165 | blobs da árvore Git da referência |
| Arquivos `.sh` | 84 | extensão, inclui testes |
| Arquivos sob `tests/` | 62 | inclui fixtures; não equivale a 62 testes executáveis |
| Arquivos sob `docs/` | 16 | diretório, não inclui README da raiz |
| `install.sh` | 2.274 linhas | contagem textual da versão de referência |
| `minecraft/install.sh` | 944 linhas | idem |
| `crias-tui.sh` | 603 linhas | idem |
| `minecraft/mc-manager.sh` | 615 linhas | idem |
| `crias-update.sh` | 481 linhas | idem |
| `shared/lib/minecraft-tuning.sh` | 541 linhas | idem |

Funções que merecem revisão de coesão: `install_crias_agent_if_enabled()` (~461 linhas até a função seguinte), `crias-tui.sh:main()` (~387), `compute_minecraft_tuning()` (~186). **Tamanho não é erro por si só**; a análise é manual.

## Lacunas da referência

- CI possui cenários recentes ausentes na lista direta de `tests/run-all.sh`. Há execução indireta via `quick-script-tests.sh`, portanto contar nomes não equivale a medir cobertura.
- `CHANGELOG.md` registra até a fase de 21/11 no início, faltando as releases de 22/11 no topo.
- `docs/tui.md` descreve TTY interativo como manual apesar dos testes recentes de PTY.
- PRs #24–#27 têm CI, mas não há evidência de homologação de mundo modded com jogadores para essa referência.
- Não foi coletado inventário confiável de incidência de bugs pós-release, sucesso de backups em hardware ou tempo de recuperação. **Valores: não medidos.**

## Método de medição para próximas alterações

Execute no checkout de cada SHA:

```bash
python3 tools/quality-report.py --format markdown
python3 tools/quality-report.py --format json > quality-report.json
# Comparação direta com a versão anterior aos fundamentos (clone com histórico completo):
python3 tools/quality-report.py --compare-ref 9496a5f04e3c2f093926f21f69b38251c11af8fe --format markdown
# Alternativa para runners rasos: salve o JSON da baseline num checkout com histórico e compare:
python3 tools/quality-report.py --compare quality-baseline.json --format markdown
```

O modo `--compare-ref` lê os arquivos **diretamente do objeto Git histórico**, mesmo que o commit antigo não contenha essa ferramenta. Em clones superficiais (`fetch-depth: 1`), obtenha o histórico necessário antes da comparação; o relatório em CI permanece apenas observacional. Não atribuir alterações locais não commitadas ao SHA do HEAD.

Comparar por módulo e explicar a diferença. O relatório automático é observacional; não há gate automático para reduzir linhas. Analisar separadamente linhas de produção, testes e documentação.

Indicadores qualitativos por PR: duplicação eliminada, superfície de erro reduzida, consumidores legados verificados, contratos preservados, casos negativos cobertos e documentação corrigida.

Indicadores operacionais somente se houver fonte: deploy com recuperação/hotfix, OOM real, restauração de backup real, desempenho sob Chunky e retorno do SSH. Jamais marcar como zero um incidente que simplesmente não foi medido.

## Hipóteses para PRs posteriores (não são correções deste PR)

1. Unificar a identificação de mods extras/QoL sem mudar políticas de instalação.
2. Isolar controladores do Hub mantendo comandos e UX estáveis.
3. Transacionar conjuntamente recalibração do heap e alterações do systemd.
4. Cobrir atualização de release anterior → atual, além da migração histórica já testada.
5. Comprovar recovery de save-on com RCON real em mundo descartável.

Arquivar uma nova seção de resultados depois de cada ciclo, preservando este estado inicial e seu SHA.

## Ciclo 1 — Deduplicação de mods (issue #29 / PR #30)

- **Referência anterior ao ciclo:** `main@645871d` (já com a política de engenharia).
- **Commit de caracterização:** `eee271c` — somente `tests/server-extras-test.sh`, passando de 23 para 147 linhas e registrando **três falhas de identificação** no comportamento original.
- **Commit funcional:** `4b45195` — `minecraft/install.sh` passa de 944 para 950 linhas; substitui **duas varreduras divergentes** por uma rotina de identificação compartilhada. O número de linhas é **+6**, e não uma meta de redução.
- **Efeito verificável:** Spark/Chunky/Skin Restorer identificados tanto por nome versionado quanto por ID de manifesto Fabric, Forge e NeoForge, incluindo arquivos renomeados. Reduz risco de downloads duplicados.
- **Contratos preservados:** filtros por loader, versão efetiva, destinos distintos de QoL e extras, SHA-256 fixado para QoL, sinalização de pendências e modo strict/best-effort. O test runner no CI já executava `tests/server-extras-test.sh`; não foi criado um segundo executor redundante.
- **Limites:** testes usam JARs de fixture e substituem a função de download; não demonstram compatibilidade real do modpack, instalação em host físico nem performance de mundos. Scanner procura manifestos em arquivos JAR locais; não valida assinatura, dependências ou versões de mods instalados.

A primeira mudança **não reduziu necessariamente as linhas totais**, mas eliminou uma divergência comprovada. O próximo ciclo deverá registrar os próprios valores e contraprovas, sem sobrescrever a referência histórica.


## Ciclo 2 — Confiabilidade da suíte local (issue #31 / PR #32)

- **Referência anterior ao ciclo:** `main@a2a3cfd` (Ciclo 1 consolidado).
- **Defeito reproduzido:** `tests/run-all.sh` contabilizava falhas, mas terminava sem verificar `FAIL > 0`; uma execução local reprovada podia retornar **exit code 0**. O primeiro commit de contrato fez o CI falhar, comprovando o problema antes da correção.
- **Deriva CI/local:** 34 testes Shell invocados diretamente no job `test-shell` do CI contra 39 listados no `run-all` anterior. **Oito** estavam somente no CI; após acrescentar a contraprova como teste 35 no CI, a lista local passa a **48 testes diretos** (39 + 8 + 1).
- **Correção:** saída final com PASS/FAIL/SKIP, lista de falhas e retorno não-zero; inclusão dos oito testes; verificação automática de alinhamento CI/local. Removido um cabeçalho duplicado.
- **Teste negativo:** a contraprova executa uma cópia isolada do runner em fixture, injeta uma falha controlada num filho e confirma o código de saída e o nome do teste reprovado. Nenhum serviço ou mundo é executado na fixture.
- **Escopo:** somente testes, CI e documentação; **zero alteração** de código produtivo ou regras de instalação/backup/JVM.
- **Limite:** `run-all.sh` não equivale à matriz de CI completa (Java, Go, integração Arch/QEMU, migração de releases e testes Python dedicados). As dependências de testes locais continuam necessárias.

A meta aqui não é diminuir linhas, e sim impedir que um problema não seja percebido e que a lista de testes locais continue divergindo do CI.


## Ciclo 3 — Controlador de memória Java do Hub (issue #33 / PR #34)

- **Referência anterior:** `main@7e0dd73` (Ciclo 2 consolidado).
- **Caracterização:** commit `3c5e10a`, 13 cenários de navegação real pelo fallback numerado (`tests/hub-memory-menu-test.sh`), preservando fluxos de status, fixed, valor manual fixo/adaptativo, auto, cancelar, entradas inválidas, retorno e Chunky. Todas as chamadas administrativas são interceptadas; nenhum servidor é alterado.
- **Refatoração:** commit `b02397b`, extrai a função `hub_minecraft_memory_menu()` no mesmo arquivo, sem biblioteca/sourcing novo e com retorno explícito ao menu principal após cancelamentos. `main()` passa de **384 para 336 linhas (-48, ~12,5%)**; `crias-tui.sh` inteiro passa de **603 para 611 linhas (+8)**. Mais linhas totais não significam aumento de complexidade aqui: uma responsabilidade deixa de estar embutida em `main()`.
- **Contratos preservados:** ordem das opções, prompts, argumentos passados ao manager, bloqueio de valores inválidos, ausência de ação ao cancelar, e sem reiniciar automaticamente o jogo; menu Chunky adjacente continua com a mesma seleção de intervalos.
- **Limites:** os novos testes cobrem o fallback numerado com `sudo` stubado e não afirmam homologação SSH/TTY real ou funcionamento do mundo. Os testes existentes de Hub/Gum/PTy e QEMU continuam sendo necessários.


## Ciclo 4 — Atalhos de arquivos no Hub (issue #35 / PR #36)

- **Referência antes da mudança:** `main@6f5e9cf` (ciclo 3 integrado).
- **Testes anteriores à extração:** commit `a190bd2`, acrescenta `tests/hub-files-menu-test.sh` com **17 cenários** que exercitam entrada real no menu numerado para Minecraft e Terraria, seis atalhos, confirmação/cancelamento de `setup-files`, falha da chamada `files`, retorno, entrada inválida e menu adjacente Voice Chat. As chamadas administrativas são simuladas. O CI e o runner local incluem o novo teste.
- **Extração:** commit `8796f66`, move somente o submenu para `hub_files_menu(stack, manager_script)`, no próprio arquivo. `crias-tui.sh:main()` passa de **336 para 301 linhas (-35; ~10,4%)**. `crias-tui.sh` completo passa de **611 para 619 linhas (+8)**, enquanto seu texto fica ~144 caracteres menor (27.556 para 27.412 caracteres Unicode, medidos no código carregado). A intenção é reduzir responsabilidades, não maximizar corte de linhas.
- **Contratos preservados:** títulos, ordem de escolhas, `root/world/mods/config/backups/logs`, `setup-files` sob confirmação, mensagens/pausas, retorno sem efeito ao cancelar e caminhos de manager separados para as duas stacks.
- **Segurança e limites:** nenhuma alteração em `mc-manager.sh`, `tt-manager.sh`, `sudo`, `systemd`, diretórios persistidos, ou privilégios. O teste existente `tests/hub-files-test.sh` valida os limites de diretório, execução como usuário do jogo e rejeição de symlinks em pseudo-TTY. Testes do menu usam comandos stubados e não substituem uma verificação em sessão SSH física.


## Ciclo 5 — Controlador Voice Chat do Hub (issue #39 / PR #40)

- **Referência anterior:** `main@6faf9f9` (ciclo 4 mesclado, CI pós-merge concluído com sucesso).
- **Caracterização:** `686eaab` acrescenta `tests/hub-voicechat-menu-test.sh`, com **14 cenários de fallback numérico** e **2 cenários de pseudo-TTY/Gum input**. Exercita status e falhas do manager, editar, porta, Enter/EOF, network, voltar, opção inválida, menu adjacente Arquivos e ausência de Voice Chat no Terraria. Todas as chamadas administrativas são simuladas.
- **Refatoração:** `18ca10b` extrai `hub_minecraft_voicechat_menu(manager_script)` no mesmo script, sem novos imports nem mudança persistida. `main()` passa de **301 para 269 linhas (−32; ~10,6%)**; `crias-tui.sh` completo passa de **619 para 627 linhas (+8)**. O ganho é a responsabilidade isolada e protegida por contratos.
- **Comportamento mantido:** opções, ordem, prompts, comandos enviados ao manager, `|| true`, pausas de retorno, cancela/volta e disponibilidade exclusivamente para Minecraft. As cinco saídas `continue` originalmente associadas ao submenu passam a `return 0` no controlador, retornando ao mesmo laço principal.
- **Fronteira de segurança:** `minecraft/voicechat-tools.sh` permanece inalterado, com os testes existentes de validação de portas, colisão com a porta do jogo, proibição de symlinks e restrições de terminal em `tests/minecraft-voicechat-test.sh`. Os novos testes não alteram o servidor real ou a interface do firewall; os cenários de pseudo-TTY verificam controle de fluxo, não conexão real.


## Ciclo 6 — Monitoramento do Hub (issue #41 / PR #42)

- **Base:** `main@eba7779` após ciclo 5, `crias-tui.sh` com 627 linhas, `main()` com 269.
- **Caracterização pré-refatoração:** commit `0b65507`, novo `tests/hub-monitoring-menu-test.sh` com **10 casos**: atalhos btop/ncdu, escolha vazia/inválida, EOF, voltar, equivalência Minecraft/Terraria e opção adjacente Arquivos. O teste invoca o menu real em fallback numerado e intercepta `sudo`, evitando execução de ferramentas/serviços.
- **Extração:** commit `a6f81fe`, move apenas a escolha para `hub_monitoring_menu(manager_script)` no mesmo script; `main()` **269 → 260 linhas (−9; ~3,3%)**, `crias-tui.sh` **627 → 635 linhas (+8)**. O pequeno ganho na função principal não justifica alterações maiores fora de escopo.
- **Contratos:** textos, ordem de opções, argumentos exatos dos managers, tratamento de retorno e acesso a ambos os jogos mantidos; o caminho de Gum/TTY já é coberto por testes gerais existentes do Hub.
- **Limite:** testes simulam `sudo`; não executam `btop`/`ncdu` em host real e não medem desempenho nem experiência SSH. A função não altera privilégios, hardware ou regras de monitoramento.


## Ciclo 7 — Controlador Atualizações do Hub (issue #43 / PR #44)

- **Base:** `main@e6b8dfd` após ciclo 6, `crias-tui.sh` com 635 linhas e `main()` com 260.
- **Caracterização pré-refatoração:** commit `218d138`, novo `tests/hub-updates-menu-test.sh` com **23 cenários** do menu numerado real. São simulados, sem executar comandos reais, os caminhos do atualizador em `/usr/local/bin/crias-update`, `sudo` e a checagem de permissão `-x`. Verifica `check`, `arch-check`, `apply`, `arch-apply`, confirmações positivas/negativas, falta do executável, erros, volta, EOF e menu adjacente em Minecraft/Terraria.
- **Extração:** commit `66b70e2`, move somente o submenu para `hub_updates_menu()` no mesmo `crias-tui.sh`; `main()` **260 → 219 linhas (−41; ~15,8%)**, arquivo completo **635 → 642 linhas (+7)**. Cinco `continue` de cancelamento/retorno ao menu principal tornam-se `return 0` no novo controlador; não muda o laço principal.
- **Fronteira preservada:** consultas sem privilégio, mutações apenas sob confirmação e `sudo`, path fixo do atualizador, mensagens e `|| true` idênticos; `crias-update.sh`, migração real e política de manutenção não sofrem alteração.
- **Limites:** os testes novos são contraprovas de navegação e de argumentos com chamadas simuladas. Não exercitam rede real, atualização em host ativo ou problemas de manutenção do Arch; os testes existentes de atualização e migração com releases oficiais em CI continuam obrigatórios. Não houve release neste ciclo.
