# C02 — Crias Forest: design system e layout inicial

Base: M1 experimental validado em 9f44ca2, consolidado em d20fa57.
PR dependente de #45 e #46; sem troca do Hub Bash nem operações de host.

## C02.1 / C02.2 — Fundação visual

A interface pura vive em crias-hub/internal/ui, enquanto app mantém o
estado e cmd apenas adapta eventos Bubble Tea. Sem I/O, timers, coletores,
comandos administrativos, dados sintéticos ou nova dependência.

| Token | Cor | Papel |
|---|---|---|
| forestBackground | #111713 | Fundo das linhas estilizadas |
| forestSurface | #202E24 | Faixa de abas |
| forestAccent | #94D5A5 | Títulos e destaque |
| forestMuted | #91A89A | Informação secundária |
| forestText | #DCE9DF | Texto principal |

A aba ativa tem colchetes e número, inclusive sem cor. Lip Gloss realiza
estilização; negociação de cores limitadas depende do terminal/renderizador
e será testada em C02.4. Modo NO_COLOR mantém texto; CRIAS_HUB_ASCII=1
translitera os rótulos fixos. Sem fontes especiais, sem animações.

Layout amplo a partir de 100x30: abas superiores, área central e coluna
contextual. Entre 60x20 e 99x29: abas quebram em linhas e lateral oculta.
Abaixo disso: título, área atual e rodapé reduzido. A margem de uma coluna
evita auto-wrap; altura limitada, sem cortar UTF-8. Dados dinâmicos e
graphemes arbitrários precisam de tratamento específico antes de C03.
Labels PT-BR são canônicos no estado; nenhuma duplicação de navegação.

O foco permanece no contrato C01 (1–6, setas horizontais, Tab/Shift+Tab,
Enter, Esc, Q/Ctrl+C). A coluna é contextual passiva; toggle, foco
explícito, busca e ajuda serão implementados em C02.3. Não declarar
funcionalidades de monitoramento/gerenciamento entregues: placeholders
informam indisponibilidade (C03/C04).

## Validação

Matriz unitária de 8 tamanhos, 6 abas, detalhe aberto/fechado, quatro
combinações ASCII/cor; valida largura/altura, UTF-8, ausência de ANSI em
NO_COLOR, ASCII e estado ativo/contexto. Benchmark de renderização.
O harness PTY legado usa ASCII explícito para preservar marcadores;
o resultado C02 será identificado como apresentação Hub, separado da
baseline C01. Testes de terminal, race, scanner e CI ainda pendentes
neste candidato; não publicar resultado inventado. Não há artefato
distribuído; rollback é descartar binário experimental.

## Próximas etapas

- C02.3: foco, busca navegacional, atalhos contextuais e lateral ocultável.
- C02.4: contraste, terminais limitados, PTY em múltiplos tamanhos/modos.
- C02.5: auditoria de layout, latência/RSS e regressões, evidências, CI.
Gates físicos/SSH, métricas reais e segurança dos ciclos seguintes
continuam intactos. M2 depende de C03.

## C02.3 — Navegação contextual (candidato)

O job Hub 139437063138 do run 45679818006 aprovou o primeiro layout:
384 combinações, race/vet, PTY e scanner sem alertas. 30 startups e 60
transições, startup mediano 22.816 ms, p95 de navegação 17.143 ms,
RSS principal 5888 KiB, binário 5692436 bytes. QEMU/build agente ainda
pendentes na consulta; não declarar CI integral.

O novo estado mantém foco explícito (abas, conteúdo, contexto), F6
cicla regiões disponíveis, F2 oculta/mostra a lateral; resize e ocultação
retiram foco de regiões invisíveis. Tab/setas continuam a navegação do
C01. Enter em contexto passivo não executa nada. Esc prioriza overlay,
detalhe e foco antes de sair. Ctrl+C sempre permite restaurar terminal.

Busca / navega somente para uma das seis áreas. Pesquisa por rótulos e
aliases de conteúdo (ex.: RAM, Minecraft, Doctor), insensível a caixa e
acentos portugueses. Query limitada a 48 runes, aceita ASCII imprimível
e letras portuguesas; rejeita sequências de controle e colagens
multicaractere. Enter sem resultado não altera estado. Q, números e
atalhos globais ficam suspensos dentro da busca; ? abre ajuda modal,
Esc fecha e restaura foco. Não há execução de comandos, serviços ou
consultas de host. Renderização de texto dinâmico arbitrário permanece
fora de escopo. Atalhos F2/F6 e PTY real ainda precisam ser comprovados.

Testes unitários novos: busca, limites, seleção circular, isolamento,
foco, resize e lateral; teste PTY busca e ajuda. Preparação em branch
temporária para preservar CI anterior. Nenhuma mudança de workflow.

A matriz de overlays acrescenta 112 combinações (7 tamanhos, 4 estados,
4 modos), inclusive seleção visível em 40x5. Marcadores PTY observam
fragmentos emitidos pelo renderer, não presumem uma linha inteira após
cada atualização; as transições completas são verificadas em testes puros.

## C02.4 — Acessibilidade e compatibilidade inicial

CI de db9df03 (45679818006) terminou success: 15 jobs, inclusive QEMU,
release ignorada. Candidato C02.3 em branch temporária revisado antes de
integração. Corrigida formatação da declaração adjacente de New/Section.

Modo de cores limitado: TERM linux/ansi ou CRIAS_HUB_COLOR=16 usa destaque
ANSI sem fundo forçado; TERM vt100/vt220 usa ASCII/monocromático. NO_COLOR
tem precedência; não assumir a paleta RGB do usuário em modo ANSI.
Teste de contraste relativo sRGB exige 4,5:1 nos quatro pares utilizados
pelo tema explícito. Isso não é certificação de acessibilidade do
terminal; contraste de paletas customizadas e renderização real ainda
dependem do emulador. Seleção e foco textuais permanecem sem cor.
Rodapé compacto prioriza sair e ajuda; foco visível quando altura permite.

Matriz de layout expandida a 576 combinações e overlays a 168 (seis modos
de apresentação). Testes de seleção de perfil; quatro novas sessões PTY
100x30, 80x24, 60x20, 40x15, Unicode/ASCII e com/sem cor, incluindo TERM
linux. PTY simula TERM, não emula pixels nem comprova terminal físico.
Teste de sinais e restauração preservado. Novos testes aguardam CI.
Sem novas dependências, operações administrativas, mudança no workflow
ou coletores. Restam revisão dos atalhos físicos, refinamento e evidências.

## C02.5 — Auditoria e refinamento final (candidato)

Run 45681991824, commit 020a662, 15 jobs aprovados, release ignorada.
Job Hub 139444649181: 576 combinações de layout, 168 de overlays,
contraste, perfis de terminal, busca/ajuda, 12 grupos PTY e govulncheck
sem alertas. Evidências de db9df03 e 020a662 em
[evidence/hub-c02/pty-layout-navigation.json](evidence/hub-c02/pty-layout-navigation.json).
Estatísticas recalculadas dos 30 startups e 60 transições por candidato.

| Métrica | C02 inicial | C02.4 |
|---|---:|---:|
| Startup mediano (ms) | 22.816 | 21.844 |
| Navegação p95 (ms) | 17.143 | 17.318 |
| RSS principal mediana (KiB) | 5888 | 5760 |
| Binário (bytes) | 5692436 | 5718926 |

Ambiente Ubuntu, kernel 6.8.0-1070-azure, Go 1.27.4, PTY 120x40,
ASCII/NO_COLOR. Runners distintos; observação, não teste estatístico.
Sem coletores, jogos ou SSH real. Zero ticks ociosos em janela de 5 s
não prova consumo permanentemente nulo.

Contraprova: em viewport menor que 24x5, a busca não permite Enter
selecionar um resultado invisível; conserva consulta/seleção até resize
ou Esc. Rodapé específico para detalhes, teste de retorno de foco e
lateral oculta; novo PTY envia sequências xterm F6 e F2, confirma mudança
de foco e restauração após Esc. Marcadores são fragmentos observados,
não reconstrução do framebuffer. Testes do refinamento ainda pendentes.
Nenhuma dependência nova, alteração de workflow ou ação administrativa.
Foco atual usa F6 para alternar região, Tab/setas para abas; busca restrita
às seis áreas e aliases, não catálogo de ações. C03 introduzirá métricas reais.
Gates Arch/SSH físico, equivalência administrativa, carga de jogo,
estabilidade prolongada e homologação permanecem obrigatórios. M2 ainda
depende de C03. Não publicar ou alterar ponto de entrada.

## C02.6 — Encerramento experimental

Run [45683390200](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45683390200),
32263c6: 15 jobs aprovados, QEMU incluso, release ignorada. Hub
139449503792: 13 grupos PTY, F2/F6 e retorno de foco, race/vet e scanner
sem alertas. Dados brutos e estatísticas conferidas em
[evidence/hub-c02/pty-final-32263c6.json](evidence/hub-c02/pty-final-32263c6.json).
30 startups e 60 transições; startup mediano 19.003 ms, navegação p95
17.121 ms, RSS principal mediana 5760 KiB, binário 5719350 bytes.

C02 experimental concluído em 32263c6. A UI mantém navegação por abas e
F6 para foco, busca somente por áreas e modo compacto. Sem telemetria
real, operações administrativas, integração na main ou distribuição.
PTY local não comprova SSH, Arch Go no guest ou renderização física;
comparações de carga e gates físicos C00/C04/C10/C11 preservados.
M2 depende da implementação e validação de C03. CI do registro
posterior deve ser identificado separadamente por SHA.
