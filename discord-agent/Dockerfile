# discord-agent/Dockerfile
#
# Build multi-stage do crias-agent. Resulta em imagem scratch ~5-10 MB.
# Build: docker build -t crias-agent:latest -f discord-agent/Dockerfile discord-agent/

# --- Stage 1: builder ---
FROM golang:1.22-alpine AS builder

# Instala protoc + plugins + ca-certificates (necessário para https em runtime).
RUN apk add --no-cache protobuf-dev git make build-base \
    && go install google.golang.org/protobuf/cmd/protoc-gen-go@latest \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

ENV PATH="$PATH:/root/go/bin"

WORKDIR /app

# Cache de dependências: copia go.mod/go.sum primeiro.
COPY go.mod go.sum ./
RUN go mod download

# Copia resto do código + proto.
COPY . .

# Gera código proto + build.
RUN make proto \
    && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
       go build \
        -ldflags "-s -w -X main.version=$(git describe --tags --always --dirty 2>/dev/null || echo docker)" \
        -o /out/crias-agent \
        ./cmd/crias-agent

# --- Stage 2: runtime (scratch) ---
FROM scratch

# CA certs para HTTPS (Tailscale Funnel exige).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# Binário.
COPY --from=builder /out/crias-agent /opt/crias-agent/crias-agent

# Config default (NÃO contém secrets; token vem de /etc/crias/agent.yaml em runtime).
COPY agent.example.yaml /etc/crias/agent.yaml

EXPOSE 8473

ENTRYPOINT ["/opt/crias-agent/crias-agent"]
CMD ["-config", "/etc/crias/agent.yaml"]
