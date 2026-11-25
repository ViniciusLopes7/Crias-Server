# C00 — Auditoria e baseline pré-Go

Estado: iniciado, gate ainda aberto. Data: 25/11/2026. Escopo: [#22](https://github.com/ViniciusLopes7/Crias-Server/issues/22).

## Referência estática

Checkout observado: main@ee247bc39e6f4cab5bc3ea94595f6c1d19ca96a4, antes de alterações C00. Consulta ao GitHub: nenhum PR aberto retornado; #44 é o PR encerrado mais recente, seguido de #42, #40, #38 e #36. A consulta de status combinados e runs (restrita a pull_request) retornou listas vazias; CI pós-merge não confirmado. Inventário de releases atuais ainda não verificado (o conector usado não oferece listagem de releases). Nenhum workspace/host executável foi disponibilizado para medição. Não inferir sucesso ou disponibilidade de releases dessas ausências.

| Arquivo | Linhas (documentação/contagem textual) | Blob Git |
|---|---:|---|
| crias-tui.sh | 642 | 77573f24b987dc1bcbe9a8a1a1c447413d00d573 |
| shared/lib/manager-common.sh | 411 | a0b83565b36aa824afe0364ed46e49cf8ea200dd |
| minecraft/mc-manager.sh | 615 | b6f5b20dbc118a8e87f2bf3649170f150fa68bb2 |
| terraria/tt-manager.sh | 228 | b77dfb2c7a86771245a920fcbc15572c1cf43e0f |
| crias-update.sh | 481 | 8997284d167ce23db2854ee7772d9e9a62f5178e |

A contagem é de texto retornado pelo conector, não uma execução de wc; conferir no checkout. O histórico em [quality-baseline.md](quality-baseline.md) registra main() 384 → 219 linhas (ciclos 3–7), arquivo Hub 603 → 642; extração de responsabilidades, não ganho de desempenho medido. Preservar referência histórica 9496a5f.

## Matriz de paridade — inventário inicial de código

Legenda: B = rota Bash existente; C = CLI existente sem rota direta ou com acesso indireto; NA = não aplicável; N = nova capacidade planejada. Nenhuma rota Go implementada. Todos os itens exigem teste de contrato antes de marcar paridade.

| Operação | Minecraft | Terraria | Contrato / rota futura |
|---|---|---|---|
| Estado e ciclo de vida | B | B | manager status/start/stop/restart; Servidores/Gerenciamento; preservar Conflicts entre units |
| Console padrão | B | B (logs apenas) | manager console; Servidores/Console; não prometer comandos Terraria |
| Console avançado/RCON | B | NA | console --tui e setup-console; preservar fallback por comando, sem retry de comando incerto |
| Logs recentes/boot/alertas/follow | B | B (logs gerais) | MC logs recent/boot/alerts/follow; TT logs; distinguir capacidades |
| Heap Java | B | NA | memory status/auto/fixed/set <MiB> fixed/dynamic; Servidores/Configurações; somente jogo parado |
| Chunky progresso e ajuda | B | NA | chunky watch 5/10/15/20/30/60 (Bash expõe 5/10/30/60); ajuda; adicionar 15/20 sem romper contrato |
| Chunky ações visuais | N | NA | integração RCON compatível; C05 |
| Arquivos | B | B | files root/world/mods/config/backups/logs; setup-files com confirmação; usuário do jogo |
| Voice Chat | B | NA | voicechat status/edit/set-port/network; Servidores/Voice Chat |
| Monitoramento externo | B | B | monitor cpu/disk; monitor net = C em ambos; Hardware/Sistema |
| Backup imediato/timer | B | B | backup, setup-cron; Backups |
| Restore e verificação avançada | N | N | documentação manual existe; C08/C09, não habilitar sem proteção |
| Health check | B | B | health; jogo pronto não equivale a systemd ativo |
| Perfil de hardware | B | B | hardware-report; reconfigure-hardware [LOW/MID/HIGH]; preservar validações e opt-ins |
| Atualizador ferramentas | B | B | crias-update check/apply; recover = C, incluir recuperação explícita |
| Atualização Arch | B | B | arch-check/arch-apply; jogos parados, TTY, confirmação, sem auto-reboot |
| Diagnóstico | B | B | --doctor/doctor/diagnose, inclusive stack ausente; Bash independente |
| Ajuda | C | C | --help/-h e CLI help; preservar opções e saída desconhecida |
| Jogadores/whitelist/operadores/banimentos | C via RCON / N visual | N condicional | não pressupor autenticação offline-mode; C05 |
| Mods/MRPack | C via instalador / N administração | C via instalador / N administração | manter importação genérica, staging/backup/rollback |
| Telemetria avançada | N | N | TPS/MSPT/heap real somente fonte comprovada; métricas cgroups |
| Rede, hardware ativo, tarefas, busca | N | N | C02/C03/C06–C09; segurança antes da escrita |

Fonte: crias-tui.sh (main e cinco controladores isolados), manager-common.sh (dispatch/help), managers específicos, crias-update.sh e [docs/tui.md](tui.md). A matriz é estática; ampliar para argumentos/exit codes, permissões, efeito persistente, teste existente e evidência antes do gate. Diferenciar ações disponíveis por instalação de um jogo, não presumir dois jogos executáveis ao mesmo tempo.

## Achados e bloqueadores

| ID | Achado verificável ou lacuna | Tratamento |
|---|---|---|
| C00-A | hub_ensure_gum tenta pacman -S --noconfirm gum quando TTY e Gum ausente/danificado; abertura pode alterar o host. | Caracterizar comportamento legado; nova UI nunca repara dependência implicitamente; tratar legado em alteração isolada e autorizada. |
| C00-B | detect_stack prioriza Minecraft quando ambas units existem; header reduz estado a ativo/parado. | Adaptadores enumeram capacidades e estados reais, preservam conflitos e exigem alvo explícito. |
| C00-C | Managers imprimem mensagens humanas e alguns caminhos interativos; contratos tipados ainda não definidos. | Caracterizar códigos/argumentos, separar dados de apresentação em mudanças pequenas, não depender de parsing ANSI frágil. |
| C00-D | docs/architecture.md registra lacuna transacional no reconfigure-hardware; backup usa traps que não garantem save-on após SIGKILL/OOM. | Manter bloqueio das novas ações críticas até demonstrar recuperação independente. |
| C00-E | QEMU atual não inicializa mundo Minecraft jogável (EULA false); RCON/Chunky e controle de sensores físicos não homologados. | Separar testes de fixture/VM, jogo real autorizado e hardware físico; não declarar validação funcional. |
| C00-F | Status CI pós-merge e releases reais não confirmados; benchmark em host não executado. | Obter evidência em checkout/Actions e ambiente controlado antes do gate C00. |
| C00-G | ROADMAP histórico contém referências antigas a ISO/Gum/web e testes; docs atuais distinguem testes PTY do Hub. | Marcar histórico, dar precedência ao roadmap novo sem apagar rastreabilidade. |

## Protocolo de baseline de execução (pendente)

Executar em host de teste Arch ou máquina física autorizada, não em produção sem janela e não disparar ações de escrita. Fixar SHA acima, release instalada/digest, versões kernel/Java/Go (quando aplicável), CPU/RAM/cgroups, driver/perfil térmico/energia, tamanho e TERM do terminal, cliente SSH, seed e modpack (sem segredos). Usar checkout descartável e comandos existentes:

```bash
git rev-parse HEAD
python3 tools/quality-report.py --format json
python3 tools/quality-report.py --compare-ref 9496a5f --format markdown
bash tests/run-all.sh
```

Executar também checks CI aplicáveis e PTY conforme docs/tui.md. Confirmar que Gum está instalado e saudável antes de testar o Hub Bash em TTY, evitando a instalação automática apontada em C00-A. Não usar sudo para ferramentas de benchmark além de necessidade autorizada. Registrar CPU time da árvore de processos/cgroup de medição, RSS principal e PSS quando legível, pico, filhos, tráfego PTY/SSH (bytes), início até primeira tela útil e latência tecla→tela completa p95. Usar relógio monotônico, PTY automatizado e marcador verificável; não confundir tempo de fork com tela pronta. Medir energia somente com fonte e domínio identificados.

| Cenário | Duração / amostra | Estado |
|---|---|---|
| Startup local | 30 execuções, condições frias/quentes discriminadas | Não medido |
| Bash ocioso | 10 min, menu padrão | Não medido |
| Navegação Bash | 5 min, roteiro fixo sem escrita | Não medido |
| Monitoramento externo equivalente | 30 min, indicar ferramenta/intervalo | Não medido |
| Minecraft sem Hub vs Bash | 30 min por execução, repetições e ordem alternada | Não medido |
| Chunky sem Hub vs Bash | 30 min por execução, mundo descartável equivalente | Não medido |
| Estabilidade | 2 h; candidato Go também 24 h em C10 | Não medido |
| SSH/PTY | 60x20, 80x24, 100x30, 120x40; resize/saída | Não medido |

Guardar dados brutos sanitizados, resultados por SHA, mediana/p95/picos/dispersão e limitações. Não usar valores hipotéticos como baseline. O candidato Go será comparado posteriormente em trabalho equivalente e com controle sem Hub. Metas aprovadas no ADR e #22 são propostas até validação.

## Contratos administrativos — caracterização C00.2

Entradas instaladas: /usr/local/libexec/crias/mc-manager.sh e tt-manager.sh; /usr/local/bin/crias-update. Usar caminhos administrativos fixos e argumentos separados, nunca concatenação em shell. A interface não deve aceitar argumentos arbitrários a um comando privilegiado. O manager conserva autoridade sobre regras e segurança. Saídas abaixo são humanas, não protocolo JSON.

| Operação | Argumentos/capacidades | Efeito e retorno observados no código | Evidência / restrição para Go |
|---|---|---|---|
| start/stop/restart | sem argumentos de UI; ambas stacks | systemctl; falha pode encerrar o Hub Bash por errexit | novo teste de menu 52 casos; Go exibe erro e preserva sessão; não repetir automaticamente |
| status | ambas | LoadState inexistente/sem systemctl = 1; inactive/failed/unknown podem retornar 0; RAM somente active | hub-ssh-console-status-test; não tratar rc=0 como jogo pronto |
| health | ambas | porta em escuta; MC com credencial/ferramenta consulta RCON list; health limitado pode retornar 0; TT apenas porta | evidência parcial explicitada; não concluir prontidão a partir da porta |
| console / logs | MC console [--tui], logs recent/alerts/boot/follow; TT console/logs são journal | operação interativa, falha de console tratada no Hub; não ecoar segredo, nem repetir comandos incertos | hub-ssh-console-status-test e novo teste de rotas; PTY/SSH real pendentes |
| chunky watch | MC, 5/10/15/20/30/60; sintaxe inválida 2 | exige TTY, RCON local, três falhas consecutivas encerram; não cancela tarefa do jogo | chunky-progress-watch-test; usar saída/progresso somente verificado |
| memory | MC status, fixed, auto, set MiB fixed/dynamic | argumentos inválidos 2; leitura runtime.env sem symlink; escrita só inactive/failed com unit existente e orçamento validado | hub-memory-menu-test e minecraft-heap-control-test; não copiar fórmula nem reiniciar |
| files / setup-files | ambas, área enum root/mods/config/world/backups/logs; setup sem argumentos | files exige TTY, verifica usuário/caminho, executa mc como usuário do jogo; instalação explícita | hub-files-test e hub-files-menu-test; nunca executar navegador como root |
| voicechat | MC status/edit/set-port/network | delega como usuário MC; valida diretório e script administrativo | minecraft-voicechat-test e hub-voicechat-menu-test; TT rejeitar capacidade |
| monitor | cpu/disk/net | exec de ferramenta externa; retorno não-zero se indisponível; net sem rota direta no Bash | hub-monitoring-menu-test; não executar em polling |
| backup / setup-cron | ambas | backup como usuário do jogo; setup com elevação e script administrativo | testes de backup e novas rotas; não afirmar consistência por sucesso do tar |
| reconfigure-hardware | auto ou LOW/MID/HIGH, ambas | MC exige parado, atualiza heap/cotas/properties; TT não tem mesma checagem de estado e altera configurações; sem atomicidade conjunta comprovada | teste de rotas; antes de expor novas escritas, caracterizar falhas parciais e bloquear quando necessário |
| hardware-report | ambas | imprime tuning-state ou aviso se ausente; aviso não significa dados válidos | nova rota testada; ausência não é zero, não fazer source de dados do jogo |
| crias-update | check/apply/recover/arch-check/arch-apply; aridade estrita, erro de uso 2 | check/arch-check sem elevação; apply/recover exigem root e lock; arch-apply exige TTY, jogos parados e confirmação textual | hub-updates-menu-test, migração real; recover sem rota direta atual |
| doctor/help | aliases doctor/diagnose/--doctor, --help/-h | leitura, inclusive sem stack; opção desconhecida 2; doctor não deve modificar host | hub-gum-test, novo teste de fluxo sem stack; fallback Bash independente |

A UI atual chama sudo para grande parte das ações, inclusive leituras. Na migração, determinar permissões mínimas de cada consulta; não herdar root permanente. Alguns comandos não validam aridade rigorosamente: validar enum e argumentos na fronteira e caracterizar no backend antes de confiar em retorno. A CLI existente não é contrato de dados estruturados. Não mudar código produtivo para satisfazer teste de apresentação.

### Evidência de CI por SHA

- PR #45, commit e0d119a87b9e139910bca2ed16b07bfa6e2982cf: [run 45621795871](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45621795871), concluído com sucesso, incluindo QEMU e migração real; não equivale a CI pós-merge da main.
- Commit a19573ebde797234a2dc7813d30dc67962065aee: [run 45622919457](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45622919457), job Test Shell concluído com sucesso; log confirma 52 cenários de roteamento do Hub legado com ações interceptadas e teste de alinhamento CI/local. Os demais jobs não foram todos confirmados neste snapshot. O caso start com falha confirma saída 27 do Hub legado, comportamento a corrigir em Go, não requisito desejável.
- Commit b6534069336edbcd698506c62dd03be11273f1f7: harness e smoke test adicionados, execução ainda não confirmada nesta revisão.
- Releases mais recentes e baseline física continuam não verificados. O CI do PR anterior #44 foi confirmado verde; não substituir evidência de main pós-merge por CI do PR.

### Harness de benchmark parcial

```bash
# Smoke test em checkout da branch C00 (sem root)
python3 tests/hub-baseline-test.py
# Fixture isolada: duas stacks, sem systemd real
python3 tools/hub-baseline.py --stack minecraft --samples 30 > baseline-fixture-mc.json
python3 tools/hub-baseline.py --stack terraria --samples 30 > baseline-fixture-tt.json
# Host Arch de teste autorizado: descoberta real somente leitura; fallback numérico
python3 tools/hub-baseline.py --mode host --samples 30 > baseline-host-numeric.json
```

Usar exclusivamente script Bash confiável da referência acima; opção --hub aponta para checkout fixado, não para código desconhecido. O harness desativa Gum e a recuperação automática de pacote, bloqueia sudo/pacman e percorre somente menu Servidor → voltar → sair. Não rodar como root. Em modo host, apenas descoberta/status do host são reais. Em fixture, também são simulados. O resultado JSON inclui hash SHA-256 do Hub, kernel, arquitetura, amostras cruas, mediana/p95 de startup e duas transições, RSS pontual do processo Bash (não pico/PSS/árvore) e CPU time da amostra completa (não CPU ociosa). Timeout, saída inesperada e falhas invalidam a medição; saída não contém logs ou segredos do host. Executar em ambiente controlado e registrar condições externas. Não comparar o fallback numérico com Gum ou Go full screen como trabalho equivalente. Falta baseline de Gum real, ociosidade, tráfego SSH, carga dos jogos, PSS/CPU agregada e estabilidade longa; gate C00 permanece aberto.

## C00.3 — Contraprovas de backend e evidências de execução

- [Run 45623184068](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45623184068), commit 7433663fc76d57b37dfe2184335a590038448991: Test Shell (job 139236590543) concluído com sucesso. Log confirma smoke PTY em ambas stacks, JSON e argumento inválido, além dos 52 casos de menu. QEMU ainda em execução no snapshot consultado; não declarar workflow completo.
- No mesmo run, job 139236590393 de migração real concluído com sucesso. Logs confirmam download e SHA-256 dos ZIPs oficiais imutáveis, fluxo bootstrap --update-tools e updater candidato sobre release antiga, preservação de configuração, mundos, mods e ferramentas. Referências efetivamente verificadas:

| Release | SHA-256 de crias-server-slim.zip |
|---|---|
| v2026.11.22-8877a39 | 06de2666d20739d69af7882da9943b39aa8694b3dd15740b64e6acc251ea3020 |
| v2026.11.22-9496a5f | 8f945aebd3537850eb04012908f2c2ae4f51450d8a3924ad5383e39278119867 |

Não confundir releases fixadas com a release mais recente do repositório ou a instalada no notebook; ambas continuam sem verificação direta.

- Commit 9b292b51c4bcd8efdbdec12c688228e4c82c9d59: testes adicionais de contratos reais de manager-common.sh, com systemctl simulado e fronteira de escrita interceptada. Casos de serviço ausente/estado desconhecido, recursos inválidos vs zero, falha de start/stop/restart e ausência de retry, backup ausente, tuning ausente, argumentos inválidos e funções opcionais indisponíveis. A caracterização não legitima limitações legadas; status e hardware-report podem retornar zero sem indicar prontidão/dados válidos. Testes integrados atomicamente ao CI e run-all; execução ainda pendente neste snapshot.
- Commit b362dd6abeea619fb46d943ecabc3aba7bb68566: etapa observacional no job Test Shell existente, 30 amostras por stack com fixtures, relatório completo em linhas HUB_BASELINE_JSON. Falhas de execução/JSON são erros; tempos não são gates. Sem serviço permanente, sem novos workflows ou artefatos adicionais. Extrair e guardar relatórios sanitizados por SHA quando executados; ainda não há resultados numéricos confirmados. Essas amostras não substituem a baseline física nem a medição Gum/SSH.

### Critérios remanescentes

A caracterização inicial e a validação do harness estão comprovadas pelo CI de 7433663. A suíte adicional, o CI do candidato e as amostras observacionais ainda precisam ser confirmados. Para completar a baseline, é necessário executar o roteiro em ambiente Arch controlado com Gum saudável e acesso ao host/jogos de teste autorizado; registrar resultados do modo normal, ociosidade, tráfego, processos filhos e impacto nos jogos. Sem alterar produção ou declarar comparação equivalente a partir de fixture. Preservar gate C00.

## C00.4 — Primeira baseline observacional registrada

O [run 45623870933](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45623870933), commit `38667bbab01b1fffaab33fb7fb41a7375ed1a7c3`, terminou com sucesso (13 jobs aprovados; release ignorada). Test Shell (139238997089) confirmou smoke PTY, 52 cenários de rotas e 39 de contratos de backend. QEMU e migração real também aprovados. Evidência de PR, não de CI pós-merge.

Dados brutos preservados em [evidence/hub-c00/numeric-fixture-38667bb.json](evidence/hub-c00/numeric-fixture-38667bb.json), extraídos das duas linhas HUB_BASELINE_JSON; contagens, mediana, p95 nearest rank e máximos recalculados a partir das amostras e conferidos. Ambiente: runner ubuntu-22.04, kernel 6.8.0-1070-azure, x86_64, TERM=dumb, fixture, Gum desativado. SHA-256 do script: `0fce6d3e1943e30fee8bda5da19b6240c5bba4e3106737579502777bffb74367`.

| Métrica | Minecraft | Terraria |
|---|---:|---:|
| Inicialização mediana (ms) | 5.368447 | 5.392701 |
| Inicialização p95 (ms) | 5.714294 | 5.602701 |
| Navegação mediana (ms) | 0.910744 | 0.853408 |
| Navegação p95 (ms) | 0.961666 | 0.932397 |
| RSS pontual mediana (KiB) | 3848 | 3844 |
| CPU total mediana por amostra (ms) | 7.827 | 7.777 |

30 execuções e 60 transições por stack. Não há medições de Gum, SSH, ociosidade, árvore de processos, impacto em jogos ou hardware físico. Não usar estes valores como gate temporal nem como comparação direta com dashboard Go completo. O host Arch e a release vigente/instalada seguem sem confirmação. C00 permanece aberto até validar ou isolar os bloqueadores conforme as decisões aprovadas.

## Gate C00

- [x] Referência de código fixada e leitura inicial de main/PRs.
- [x] Inventário estático inicial e riscos registrados.
- [x] Decisões permanentes e roadmap propostos em branch C00.
- [ ] Confirmar CI e releases atuais, condições de instalação e dependências.
- [x] Caracterização inicial de contratos e 52 novos cenários de rotas, executados no CI do commit a19573e.
- [x] Validar harness PTY e JSON em CI (7433663, Test Shell).
- [x] Casos negativos de backend e CI de 38667bb aprovados (39 cenários adicionais; 13 jobs).
- [x] Dados observacionais de 30 amostras por stack preservados com origem e limitações.
- [ ] Capturar baseline de execução com dados reais e arquivar evidências.
- [ ] Resolver ou isolar bloqueadores e validar C00 antes de C01.

Não há código Go, mudança de runtime, merge ou release neste ciclo; as mudanças adicionais são exclusivamente testes, ferramenta de medição e documentação.
