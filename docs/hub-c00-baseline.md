# C00 — Auditoria e baseline pré-Go

Estado: iniciado, gate ainda aberto. Data: 25/11/2026. Escopo: [#22](https://github.com/ViniciusLopes7/Crias-Server/issues/22).

## Referência estática

Checkout observado: main@ee247bc39e6f4cab5bc3ea94595f6c1d19ca96a4, antes de alterações C00. Consulta ao GitHub: nenhum PR aberto retornado; #44 é o PR encerrado mais recente, seguido de #42, #40, #38 e #36. A consulta de status combinados e runs (restrita a pull_request) retornou listas vazias; CI pós-merge não confirmado. Inventário de releases atuais ainda não verificado (o conector usado não oferece listagem de releases). Nenhum workspace/host executável foi disponibilizado para medição. Não inferir sucesso ou disponibilidade de releases dessas ausências.

| Arquivo | Linhas (documentação/contagem textual) | Blob Git |
|---|---:|---|
| crias-tui.sh | 642 | 77573f24b987dc1bcbe9a8a1a1c447413d00d573 |
| shared/lib/manager-common.sh | 411 | a0b83565b36aa824afe0364ed46e49cf8ea200dd |
| minecraft/mc-manager.sh | 615 | b6f5b20dbc118a8e87f2bf3649170f150fa68bb2 |
| terraria/tt-manager.sh | 228 | b77dfb2c7a86771245a920f63e0f |
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

## Gate C00

- [x] Referência de código fixada e leitura inicial de main/PRs.
- [x] Inventário estático inicial e riscos registrados.
- [x] Decisões permanentes e roadmap propostos em branch C00.
- [ ] Confirmar CI e releases atuais, condições de instalação e dependências.
- [ ] Completar matriz de contratos e testes de caracterização com execução.
- [ ] Capturar baseline de execução com dados reais e arquivar evidências.
- [ ] Resolver ou isolar bloqueadores e validar C00 antes de C01.

Não há código Go, mudança de runtime, merge ou release neste ciclo documental inicial.
