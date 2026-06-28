# discord-agent/NOTES.md

Notas sobre o estado atual do agente Go.

## Como buildar localmente

O código é production-ready mas requer 2 passos manuais antes de compilar (o CI faz automaticamente):

```bash
cd discord-agent/

# 1. Instalar plugins protoc (uma vez)
make install-deps

# 2. Gerar código protobuf + go.sum
make proto
make tidy

# 3. Build
make build          # gera build/crias-agent-linux-amd64

# 4. Testes
make test           # roda go test -race
```

## Por que não commitar `go.sum` e `*.pb.go`?

- `go.sum` muda frequentemente conforme dependências são atualizadas; melhor gerá-lo via `go mod tidy` para evitar hashes stale.
- `*.pb.go` é código gerado a partir de `.proto`; committá-lo gera diffs ruidosos e pode sair de sync. Melhor regenerar via `make proto`.

Caso queira committar (`*.pb.go` e `go.sum`), basta:
- Remover `internal/proto/*.pb.go` do `.gitignore`
- Rodar `make proto` e `go mod tidy` e commitar o resultado.

## Estado de implementação

Tudo pronto. Veja [ROADMAP.md](../ROADMAP.md) para status consolidado.

## Próximos passos

Veja [ROADMAP.md](../ROADMAP.md) — seção "Planejado (Pós-v1.0.0)".
