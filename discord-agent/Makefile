# discord-agent/Makefile
#
# Build e test do agente Go. Requer:
#   - go 1.22+
#   - protoc + protoc-gen-go + protoc-gen-go-grpc (para regenerar proto)

PROTOC ?= protoc
GO ?= go
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
BUILD_OS ?= linux
BUILD_ARCH ?= amd64

# DEP-005: versões pinadas dos plugins protoc para builds reprodutíveis.
# Bumpar explicitamente via PR (Dependabot friendly).
# Nota: protoc-gen-go-grpc é módulo próprio (google.golang.org/grpc/cmd/protoc-gen-go-grpc)
# com versionamento independente do grpc-go principal (não segue v1.84.0).
PROTOC_GEN_GO_VERSION ?= v1.36.12
PROTOC_GEN_GO_GRPC_VERSION ?= v1.6.2

.PHONY: all proto tidy build test lint clean install-deps

all: proto build

# Roda go mod tidy para gerar/atualizar go.sum.
tidy:
        $(GO) mod tidy
        @echo "go.sum atualizado"

# Regenera código Go a partir de proto/crias.proto.
proto:
        @command -v $(PROTOC) >/dev/null 2>&1 || { echo "protoc nao instalado. Execute: make install-deps"; exit 1; }
        @command -v protoc-gen-go >/dev/null 2>&1 || { echo "protoc-gen-go nao instalado. Execute: make install-deps"; exit 1; }
        @command -v protoc-gen-go-grpc >/dev/null 2>&1 || { echo "protoc-gen-go-grpc nao instalado. Execute: make install-deps"; exit 1; }
        mkdir -p internal/proto
        $(PROTOC) \
                --proto_path=proto \
                --go_out=. --go_opt=module=github.com/ViniciusLopes7/Crias-Server/discord-agent \
                --go-grpc_out=. --go-grpc_opt=module=github.com/ViniciusLopes7/Crias-Server/discord-agent \
                proto/crias.proto
        @echo "Codigo Go regenerado em internal/proto/"

# Instala protoc-gen-go e protoc-gen-go-grpc.
# DEP-005: versões pinadas (não @latest) para builds reprodutíveis.
install-deps:
        $(GO) install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
        $(GO) install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)
        @echo "Plugins protoc instalados em $$GOPATH/bin"

# Build do binário (linux/amd64 por default).
# GO-007: ldflags seta main.version E internal/server.Version para garantir
# que StatusResponse.Version reflita a versão real do build (não "dev").
build:
        CGO_ENABLED=0 GOOS=$(BUILD_OS) GOARCH=$(BUILD_ARCH) \
        $(GO) build \
                -ldflags "-s -w -X main.version=$(VERSION) -X github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/server.Version=$(VERSION)" \
                -o build/crias-agent-$(BUILD_OS)-$(BUILD_ARCH) \
                ./cmd/crias-agent
        @echo "Binario: build/crias-agent-$(BUILD_OS)-$(BUILD_ARCH)"

# Build para múltiplos targets.
# Nota: apenas linux/amd64 é suportado oficialmente. A ISO é x86_64-only e o
# agente não é testado em arm64. Se precisar cross-compilar para outra arch,
# use: make build BUILD_OS=linux BUILD_ARCH=<arch>
build-all: build-linux-amd64

build-linux-amd64:
        $(MAKE) build BUILD_OS=linux BUILD_ARCH=amd64

# Roda testes unitários com relatório de cobertura.
# GO-075: -coverprofile + -covermode=atomic para gatear cobertura no CI.
test:
        $(GO) test -v -race -timeout 60s -coverprofile=coverage.txt -covermode=atomic ./...
        @$(GO) tool cover -func=coverage.txt | tail -1

# Vet + fmt.
lint:
        $(GO) vet ./...
        $(GO) fmt ./...

# Limpa artefatos de build.
clean:
        rm -rf build/
        rm -f internal/proto/*.pb.go
        rm -f coverage.txt coverage.html

# Docker build (opcional, para teste local).
docker:
        docker build -t crias-agent:dev .
