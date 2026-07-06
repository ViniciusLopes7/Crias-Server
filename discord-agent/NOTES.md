# discord-agent/NOTES.md

Notas sobre o estado atual do agente Go.

## Como buildar localmente

O código é production-ready. O `go.sum` (lockfile de integridade criptográfica)
**é commitado** no repositório — isso garante builds reprodutíveis e verificáveis
conforme recomenda a documentação oficial do Go:
https://go.dev/ref/mod#go-sum-file

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

Tudo pronto. Veja [ROADMAP.md](../ROADMAP.md) para status consolidado.

## Próximos passos

Veja [ROADMAP.md](../ROADMAP.md) — seção "Planejado (Pós-v1.0.0)".
