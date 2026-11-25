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
e ausência de mudanças no lock. Revalidação desse candidato pendente.
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

## Gate M1

- [x] Resolver e versionar grafo de dependências/lock (66cc984).
- [ ] Revalidar lock readonly e revisar vulnerabilidades.
- [x] Primeiro build, gofmt, vet e race; testes de estado e limites (ecff721).
- [ ] Revalidar build com lock fixado; verificar reprodutibilidade.
- [ ] PTY real: entrada/saída alternate screen, Q, Esc, Ctrl+C, SIGTERM,
  resize, EOF/desconexão e restauração de termios.
- [ ] Benchmark equivalente ao Bash, RSS/CPU e latência observacionais.
- [ ] Documentar limitações e evidências, CI final aprovado.

Gates físicos/SSH antes de M3/C04 e homologação C10/C11 continuam obrigatórios.
O PR C01 depende do PR #45; nenhum merge na main ou release autorizado aqui.
