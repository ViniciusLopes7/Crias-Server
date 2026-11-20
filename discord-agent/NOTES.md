# Notas de desenvolvimento — agente Go

Notas sobre o estado atual do agente Go.

## Como buildar localmente

O agente possui testes e fluxo de compilação automatizados, mas isso não garante comportamento em todos os hosts, redes e permissões. O arquivo `go.sum` registra hashes de dependências, permitindo verificar downloads de módulos; ele **não**, isoladamente, garante um build bit a bit reproduzível. Referência: https://go.dev/ref/mod#go-sum-file

```bash
cd discord-agent/

# 1. Instalar plugins protoc (uma vez)
make install-deps

# 2. Gerar código protobuf (se .proto mudou)
make proto

# 3. Build
make build          # gera build/crias-agent-linux-amd64

# 4. Testes
make test           # roda go test -race
```

> `go.sum` é gerado e atualizado com `go mod tidy`. Sempre commitar `go.sum`
> junto com `go.mod` — nunca separar os dois. Sem `go.sum`, o Go não consegue
> verificar a integridade dos módulos baixados (CWE-494).

## Sobre `*.pb.go`

- `*.pb.go` (código gerado a partir de `.proto`) permanece no `.gitignore`
  para evitar diffs ruidosos. Ele é regenerado via `make proto` (ou pelo CI)
  antes de cada build.
- Caso queira commitar `*.pb.go`, basta remover `internal/proto/*.pb.go` do
  `.gitignore` e rodar `make proto`.

## Estado de implementação

O estado dos recursos está no [ROADMAP](../ROADMAP.md) e no [README do agente](README.md). A homologação em produção depende de testes no host e de autorização para operações remotas.

## Próximos passos

Consulte o [ROADMAP](../ROADMAP.md) e a documentação de [segurança](../docs/security.md) antes de propor mudanças de privilégios ou rede.
