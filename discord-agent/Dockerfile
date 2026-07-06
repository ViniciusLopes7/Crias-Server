# discord-agent/Dockerfile
#
# Build multi-stage do crias-agent. Resulta em imagem scratch ~5-10 MB.
# Build: docker build -t crias-agent:latest -f discord-agent/Dockerfile discord-agent/

# --- Stage 1: builder ---
FROM golang:1.23-alpine AS builder

# Instala protoc + plugins + ca-certificates (necessário para https em runtime).
# Pinned versions for reproducible builds.
RUN apk add --no-cache protobuf-dev git make build-base \
    && go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.33.0 \
    && go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.3.0

ENV PATH="$PATH:/root/go/bin"

WORKDIR /app

# Cache de dependências: copia go.mod/go.sum primeiro.
COPY go.mod go.sum ./
RUN go mod download

# Copia resto do código + proto.
COPY . .

# Gera código proto + build.
# GO-007: ldflags seta main.version E internal/server.Version para garantir
# que StatusResponse.Version reflita a versão real do build (não "dev").
RUN make proto \
    && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
       go build \
        -ldflags "-s -w -X main.version=docker -X github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/server.Version=docker" \
        -o /out/crias-agent \
        ./cmd/crias-agent

# --- Stage 2: runtime (scratch) ---
FROM scratch

# CA certs para HTTPS (Tailscale Funnel exige).
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# Copy /etc/passwd so the non-root UID resolves at runtime.
# (65532 = distroless) resolves to a username; scratch has no /etc/passwd
# and Go's os/user (used by some libs) would otherwise fail or run as "root".
COPY --from=builder /etc/passwd /etc/passwd

# Binário.
COPY --from=builder /out/crias-agent /opt/crias-agent/crias-agent

# Config default (NÃO contém secrets; token vem de /etc/crias/agent.yaml em runtime).
COPY agent.example.yaml /etc/crias/agent.yaml

EXPOSE 8473/tcp

# Run as non-root (UID 65532 = distroless default).
USER 65532:65532

ENTRYPOINT ["/opt/crias-agent/crias-agent"]
CMD ["-config", "/etc/crias/agent.yaml"]
