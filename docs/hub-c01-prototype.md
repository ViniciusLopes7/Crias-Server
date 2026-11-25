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

O ambiente de edição não possui acesso ao proxy de módulos Go. A resolução
inicial ocorre no CI com go mod tidy e sumdb padrão; go.mod/go.sum efetivos
serão coletados do log, conferidos e versionados antes do gate M1. A etapa
provisória de geração de lock não será a política permanente. Não inventar
checksums nem executar com GOSUMDB=off.

## Escopo e comandos

    cd crias-hub
    go mod tidy   # apenas preparação inicial do candidato
    go test -race ./...
    go vet ./...
    go build -o /tmp/crias-tui-next ./cmd/crias-tui-next
    /tmp/crias-tui-next --help
    /tmp/crias-tui-next

Executar como usuário não-root, em terminal interativo. Se sem TTY ou TERM
dumb, recusa com orientação para Doctor Bash. As seis áreas são placeholders
de navegação, não funções entregues. Sem chamadas de manager, sudo, systemctl,
escrita, configuração persistente ou métricas fictícias. Sem instalação ou
alteração do ponto de entrada. Remover binário experimental basta para reverter.

## Gate M1

- [ ] Resolver e versionar grafo de dependências/lock; revisar vulnerabilidades.
- [ ] Build reproduzível, gofmt, vet e race; testes de estado e limites.
- [ ] PTY real: entrada/saída alternate screen, Q, Esc, Ctrl+C, SIGTERM,
  resize, EOF/desconexão e restauração de termios.
- [ ] Benchmark equivalente ao Bash, RSS/CPU e latência observacionais.
- [ ] Documentar limitações e evidências, CI final aprovado.

Gates físicos/SSH antes de M3/C04 e homologação C10/C11 continuam obrigatórios.
O PR C01 depende do PR #45; nenhum merge na main ou release autorizado aqui.
