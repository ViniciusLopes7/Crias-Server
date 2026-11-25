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

## Gate C00

- [x] Referência de código fixada e leitura inicial de main/PRs.
- [x] Inventário estático inicial e riscos registrados.
- [x] Decisões permanentes e roadmap propostos em branch C00.
- [ ] Confirmar CI e releases atuais, condições de instalação e dependências.
- [x] Caracterização inicial de contratos e 52 novos cenários de rotas, executados no CI do commit a19573e.
- [ ] Completar casos negativos de backend, conferir CI do candidato final e validar harness.
- [ ] Capturar baseline de execução com dados reais e arquivar evidências.
- [ ] Resolver ou isolar bloqueadores e validar C00 antes de C01.

Não há código Go, mudança de runtime, merge ou release neste ciclo; as mudanças adicionais são exclusivamente testes, ferramenta de medição e documentação.
