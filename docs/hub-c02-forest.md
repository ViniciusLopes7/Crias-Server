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
