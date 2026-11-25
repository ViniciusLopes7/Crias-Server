# C01 — Arquitetura e protótipo Go

Estado: implementação experimental iniciada; M1 ainda não aprovado.
Base: C00 encerrado condicionalmente em 507d4f9; gates pendentes preservados.

## Escolha candidata

Bubble Tea v2.1.2 (charm.land/bubbletea/v2), Lip Gloss v2.1.1
(charm.land/lipgloss/v2), x/term v0.47.0 para detectar TTY. Versões verificadas
na documentação pública dos módulos:
- https://pkg.go.dev/charm.land/bubbletea/v2@v2.1.2
- https://pkg.go.dev/charm.land/lipgloss/v2@v2.1.1
- https://pkg.go.dev/golang.org/x/term@v0.47.0

O agente já usa Go 1.26.0 e a CI usa 1.27.1. Módulo independente crias-hub,
sem adicionar dependências ao agente. A API v2 permite declarar alternate
screen na View e receber eventos de resize/tecla. Lip Gloss é utilizado
somente no título no C01; tema e contraste ficam para C02. Estado puro,
sem timers, I/O administrativo, coleta ou goroutines próprias.

A resolução inicial ocorreu no CI de ecff721 com go mod tidy. O go.mod
efetivo e as 42 entradas de go.sum foram extraídos do log e versionados em
66cc984. O CI passa a exigir tidy -diff, download, verify, -mod=readonly
e ausência de mudanças no lock. Revalidação aprovada no CI de 6d07067.
Não inventar checksums nem executar com GOSUMDB=off. Análise de
vulnerabilidades ainda pendente.

## Escopo e comandos

    cd crias-hub
    go mod tidy -diff
    go mod download
    go mod verify
    go test -mod=readonly -race ./...
    go vet -mod=readonly ./...
    CGO_ENABLED=0 go build -mod=readonly -trimpath -o /tmp/crias-tui-next ./cmd/crias-tui-next
    /tmp/crias-tui-next --help
    /tmp/crias-tui-next

Executar como usuário não-root, em terminal interativo. Se sem TTY ou TERM
dumb, recusa com orientação para Doctor Bash. As seis áreas são placeholders
de navegação, não funções entregues. Sem chamadas de manager, sudo, systemctl,
escrita, configuração persistente ou métricas fictícias. Sem instalação ou
alteração do ponto de entrada. Remover binário experimental basta para reverter.

## Evidências C01.1 e testes de terminal

[Run 45665157494](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45665157494),
commit ecff721: workflow success, 13 jobs aprovados e release ignorada.
Log do job 139385225722 confirma go mod verify, testes de ambos os pacotes,
gofmt, vet, race, build, ajuda/versão e rejeição sem TTY. Tamanho do binário:
5.668.730 bytes (5,41 MiB). É um protótipo sem coletores nem backend,
não uma previsão do tamanho final. Não há resultados PTY Go ainda.

Commit 513446e integra tests/hub-c01-pty-test.py ao job Go existente.
O script cria PTY controlador Linux, executa binário confiável sem root,
testa navegação, resize, Q/Esc/Ctrl+C, SIGTERM/SIGHUP, TERM=dumb e
fechamento do master. Confere termios e sequência de saída da alternate
screen quando o terminal permanece utilizável; após hangup verifica somente
saída do processo, pois o terminal já foi destruído. Timeouts e volume de
saída limitados; não usa serviços reais. Requer validação do CI.

A coleta prevista é de 30 startups e 60 transições, com RSS do processo
principal, bytes PTY e janela de idle de 5 s; resultado JSON no log
HUB_C01_PTY_JSON. Navegação entre abas do protótipo não equivale a submenu
administrativo Bash; comparar apenas observacionalmente e nunca inferir
ganho de produção. Não há descoberta de host nem monitoramento no C01.
Medições de SSH físico e carga dos jogos continuam gates posteriores.

Execução local em Linux autorizado, como usuário não-root:

    python3 ../tests/hub-c01-pty-test.py /tmp/crias-tui-next --samples 30 --idle-seconds 5

Rollback: descartar binário experimental; nenhuma instalação ou mudança
de arquivos produtivos. CHANGELOG de produção não alterado por não haver
entrega/distribuição ao usuário nesta fase.

## Evidências C01.2 — PTY e benchmark validados

[Run 45666474027](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45666474027),
commit 6d07067: 13 jobs aprovados, release ignorada. Job Go 139390024548
confirma lock readonly, gofmt/vet/race, build e sete grupos de verificações
PTY: navegação/detalhe/resize/Q, Esc, Ctrl+C, SIGTERM, SIGHUP, TERM=dumb
e hangup. O master fechado demonstra saída limitada do processo, não
restauração de um terminal já destruído.

Dados brutos: [evidence/hub-c01/pty-6d07067.json](evidence/hub-c01/pty-6d07067.json).
30 startups, 60 transições, kernel 6.8.0-1070-azure, x86_64, PTY controlador
120x40 xterm-256color, NO_COLOR. Estatísticas recalculadas e conferidas.

| Indicador | Resultado |
|---|---:|
| Startup mediano / p95 (ms) | 21.587 / 21.796 |
| Navegação mediana / p95 (ms) | 16.419 / 16.727 |
| RSS principal mediana (KiB) | 5632 |
| RSS principal p95 (KiB) | 5888 |
| Binário (bytes) | 5668730 |
| CPU ociosa (uma janela de 5 s) | 0% observados |

Sem equivalência de carga com Bash/Gum, sem consultas reais de host,
SSH físico ou jogo em execução. Não confundir zero ticks na janela curta
com consumo garantidamente nulo. Tamanho igual ao build anterior não
prova identidade byte a byte. Análise de vulnerabilidades e teste de
reprodutibilidade ainda pendentes.

## CI seletivo

Commit 6041e38 separa a validação do Hub em job próprio e limita lint,
testes e build do bot/agente a alterações relevantes, com exceções de
contrato proto, configuração CI, diff indisponível e releases/dispatch.
Ver [política e testes](ci-scope.md). A mudança de workflow dispara ambos
neste PR; economia ainda não comprovada por run independente. Sem reduzir
gates do release ou alterar branch protection.

## C01.3 — Garantias adicionais

O job independente Test Hub Go passou no run 45669875941, commit 2bce98d,
incluindo lock readonly, build e contraprovas PTY. O classificador de CI
passou seus três grupos de testes (subcasos e histórico Git real) e
selecionou ambos os componentes porque o PR modifica o workflow.
Não afirmar economia real até um run sem essa alteração acumulada.

Próximo candidato: verificações adicionais no mesmo job Hub, sem criar
workflow ou artefato extra:
- govulncheck v1.10.0, análise de código contra base pública Go, com módulos
  readonly. Uma falha bloqueia o gate; não confundir ausência de alertas
  com ausência de vulnerabilidades desconhecidas.
- Rebuild com cache Go independente, mesmo commit, toolchain e ambiente,
  comparação byte a byte e SHA-256. Isso não prova reprodutibilidade
  entre máquinas/toolchains.
- Gum v2.0.2 instalado por go install versionado somente no diretório
  temporário do runner; harness recebe diretório explícito e NO_COLOR.
  30 amostras com descoberta simulada e duas transições de navegação,
  no mesmo runner do Go, PTY 120x40 xterm-256color. Comparação limitada à
  apresentação: Bash inicia submenu e Go troca aba; RSS soma de processos
  vs RSS principal, sem PSS ou coleta de host. Nenhum ganho em produção
  pode ser inferido. Repetição física/equivalência integral continua
  obrigatória nos gates posteriores.
- Após consolidar evidências M1, reavaliar frequência de rebuild frio e
  benchmark Gum para não repetir coleta cara sem mudança relevante;
  manter testes funcionais e segurança como gates.

Versões das ferramentas consultadas em pkg.go.dev (25/11/2026):
https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck e
https://pkg.go.dev/charm.land/gum/v2/version. Instalação e execução ainda
não verificadas neste snapshot.

## C01.5 — Evidências de segurança, rebuild e apresentação

[Run 45672307862](https://github.com/ViniciusLopes7/Crias-Server/actions/runs/45672307862),
commit 9999f9c, job Hub 139410558886: sucesso confirmado. Classificador,
bot, agente e demais jobs concluídos com sucesso, exceto QEMU ainda em
execução na consulta. Não declarar workflow completo neste snapshot.

govulncheck v1.10.0: zero vulnerabilidades alcançáveis no código do protótipo;
o relatório também aponta uma vulnerabilidade em pacotes importados e 14
em módulos requeridos sem caminho de chamada identificado. Não somar
categorias como CVEs distintos. Identificadores individuais não foram
emitidos no log padrão; obter relatório detalhado antes de ampliar
funcionalidades e revisar exposição a cada mudança. Nenhuma supressão
de scanner ou flexibilização de gate. Ausência de caminho de chamada
identificado não garante ausência de vulnerabilidade.

Rebuild com cache Go independente: cmp aprovado, hashes SHA-256 idênticos:
`bcda04c380173eb10b0d5f6c77659e9e23b305dbd52797d46ee27092d5141399`. Go 1.27.1 linux/amd64,
5668730 bytes, mesma fonte/toolchain/ambiente. Não afirmar reprodução
entre máquinas.

Dados brutos em [evidence/hub-c01/comparison-9999f9c.json](evidence/hub-c01/comparison-9999f9c.json).
30 startups e 60 transições por interface; estatísticas recalculadas e
conferidas. Mesmo runner Ubuntu, kernel 6.8.0-1070-azure, PTY 120x40,
xterm-256color, NO_COLOR. Gum v2.0.2 com hash registrado.

| Métrica | Bash/Gum fixture | Go C01 |
|---|---:|---:|
| Startup mediano (ms) | 103.315 | 21.751 |
| Startup p95 (ms) | 105.459 | 22.042 |
| Navegação mediana (ms) | 125.291 | 16.419 |
| Navegação p95 (ms) | 152.412 | 17.279 |
| RSS mediana (KiB) | 31584 (sessão) | 5632 (principal) |
| CPU ociosa (% núcleo, uma janela de 5 s) | 0.599 | 0 observados |

Comparação de apresentação, não equivalência administrativa: descoberta
simulada Bash, Go sem descoberta; submenu vs troca de aba; RSS soma
páginas compartilhadas no Bash, não PSS. Zero ticks não significa CPU
sempre nula. Sem jogo, sem SSH físico, sem carga equivalente. Não usar
para prometer ganho em produção. Comparação completa permanece gate
posterior; M1 restrito ao protótipo experimental, ainda aberto até
consolidação do CI e avaliação de exposição das dependências.

## C01.6 — CI integral e revisão detalhada

O run 45672307862, commit 9999f9c, terminou integralmente com sucesso:
15 jobs aprovados, incluindo Arch/QEMU (139410558766), release ignorada.
Evidências de 1c652e1 preservadas; o estado da execução registrado no
JSON corresponde ao instante da coleta e não é reescrito.

O relatório padrão do govulncheck não exibiu IDs dos alertas não
alcançáveis. Conforme a documentação de v1.10.0
(https://pkg.go.dev/golang.org/x/vuln@v1.10.0/cmd/govulncheck),
a opção -show verbose permite obter os detalhes mantendo a análise de
alcance e o código de saída bloqueante. A varredura detalhada permanece
em todo CI do Hub, sem supressão ou troca por JSON de saída não bloqueante.

Para poupar a cota do Actions, as verificações de rebuild com cache
independente e comparação Gum de apresentação, já executadas com sucesso
em C01, passam a rodar em dispatch, tag de release e push main [release].
Os testes funcionais, benchmark PTY Go, gofmt, vet, race, lock readonly,
scanner e build continuam em toda execução. A alteração não reduz os
gates de release nem elimina a obrigação de repetir as medições no C10.
A execução deste ajuste ainda precisa ser confirmada. Antes de M1,
revisar os IDs/fixes dos alertas não alcançados; C02 não iniciado.

## C01.7 — Revisão individual e correção da toolchain

Job Hub 139417454987, run 45674263850, commit 6fca9c6: sucesso.
O relatório detalhado confirmou zero símbolos vulneráveis alcançados.
Os 15 alertas distintos são da biblioteca padrão Go 1.27.1 (nenhum
alerta de módulo externo neste relatório). O único alerta de pacote é
GO-2026-6604, específico de Windows, fora do alvo Linux do protótipo.
Os demais 14 são de módulos sem caminho de chamada identificado.

| ID | Escopo | Primeira versão corretiva na série 1.27 |
|---|---|---|
| [GO-2026-6604](https://pkg.go.dev/vuln/GO-2026-6604) | os (windows) | 1.27.2 |
| [GO-2026-6859](https://pkg.go.dev/vuln/GO-2026-6859) | stdlib | 1.27.4 |
| [GO-2026-6809](https://pkg.go.dev/vuln/GO-2026-6809) | stdlib | 1.27.3 |
| [GO-2026-6617](https://pkg.go.dev/vuln/GO-2026-6617) | stdlib | 1.27.2 |
| [GO-2026-6613](https://pkg.go.dev/vuln/GO-2026-6613) | stdlib | 1.27.2 |
| [GO-2026-6612](https://pkg.go.dev/vuln/GO-2026-6612) | stdlib | 1.27.2 |
| [GO-2026-6611](https://pkg.go.dev/vuln/GO-2026-6611) | stdlib | 1.27.2 |
| [GO-2026-6610](https://pkg.go.dev/vuln/GO-2026-6610) | stdlib | 1.27.2 |
| [GO-2026-6609](https://pkg.go.dev/vuln/GO-2026-6609) | stdlib | 1.27.2 |
| [GO-2026-6608](https://pkg.go.dev/vuln/GO-2026-6608) | stdlib | 1.27.2 |
| [GO-2026-6607](https://pkg.go.dev/vuln/GO-2026-6607) | stdlib | 1.27.2 |
| [GO-2026-6605](https://pkg.go.dev/vuln/GO-2026-6605) | stdlib | 1.27.2 |
| [GO-2026-6603](https://pkg.go.dev/vuln/GO-2026-6603) | stdlib | 1.27.2 |
| [GO-2026-6600](https://pkg.go.dev/vuln/GO-2026-6600) | stdlib | 1.27.2 |
| [GO-2026-6599](https://pkg.go.dev/vuln/GO-2026-6599) | stdlib | 1.27.2 |

A correção mais recente exigida é Go 1.27.4, publicada em 10/11/2026
([histórico oficial](https://go.dev/doc/devel/release#go1.27.4),
[versão vigente](https://go.dev/VERSION), consulta 25/11/2026).
Como o pin GO_VERSION é compartilhado, atualizar para 1.27.4 no CI
também protege futuras compilações do agente; não implica auditoria
do agente nem atualização dos binários instalados. Não alterar go.mod,
go.sum ou versões Bubble Tea/Lip Gloss sem necessidade. Reexecutar
scanner detalhado e CI completo; repetir rebuild frio no gate de release.
Dados originais em [evidence/hub-c01/vulnerability-6fca9c6.json](evidence/hub-c01/vulnerability-6fca9c6.json).
Preparado em branch temporária para não cancelar QEMU de 6fca9c6;
integração após conclusão. A correção ainda não está comprovada por novo
scan. Nenhuma supressão de alerta. M1 aberto até confirmação do candidato.

## Gate M1

- [x] Resolver e versionar grafo de dependências/lock (66cc984).
- [x] Revalidar lock readonly (6d07067).
- [x] Varredura govulncheck no protótipo (zero alcançáveis, 9999f9c).
- [x] Identificar e revisar os 15 alertas não alcançáveis (6fca9c6).
- [ ] Validar Go 1.27.4 e repetir govulncheck antes de ampliar funcionalidades.
- [x] Primeiro build, gofmt, vet e race; testes de estado e limites (ecff721).
- [x] Revalidar build com lock fixado (6d07067).
- [x] Reprodutibilidade byte a byte com caches independentes (9999f9c, mesmo ambiente).
- [x] PTY real: entrada/saída alternate screen, Q, Esc, Ctrl+C, SIGTERM,
  resize, EOF/desconexão e restauração de termios.
- [x] Benchmark observacional do protótipo em PTY, RSS/CPU e latência.
- [x] Comparação observacional de apresentação no mesmo runner (9999f9c).
- [ ] Comparação administrativa equivalente permanece obrigatória antes da homologação, conforme gates físicos.
- [ ] Documentar limitações e evidências, CI final aprovado.

Gates físicos/SSH antes de M3/C04 e homologação C10/C11 continuam obrigatórios.
O PR C01 depende do PR #45; nenhum merge na main ou release autorizado aqui.
