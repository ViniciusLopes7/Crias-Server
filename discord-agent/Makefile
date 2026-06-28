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
install-deps:
	$(GO) install google.golang.org/protobuf/cmd/protoc-gen-go@latest
	$(GO) install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
	@echo "Plugins protoc instalados em $$GOPATH/bin"

# Build do binário (linux/amd64 por default).
build:
	CGO_ENABLED=0 GOOS=$(BUILD_OS) GOARCH=$(BUILD_ARCH) \
	$(GO) build \
		-ldflags "-s -w -X main.version=$(VERSION)" \
		-o build/crias-agent-$(BUILD_OS)-$(BUILD_ARCH) \
		./cmd/crias-agent
	@echo "Binario: build/crias-agent-$(BUILD_OS)-$(BUILD_ARCH)"

# Build para múltiplos targets.
build-all: build-linux-amd64 build-linux-arm64

build-linux-amd64:
	$(MAKE) build BUILD_OS=linux BUILD_ARCH=amd64

build-linux-arm64:
	$(MAKE) build BUILD_OS=linux BUILD_ARCH=arm64

# Roda testes unitários.
test:
	$(GO) test -v -race -timeout 60s ./...

# Vet + fmt.
lint:
	$(GO) vet ./...
	$(GO) fmt ./...

# Limpa artefatos de build.
clean:
	rm -rf build/
	rm -f internal/proto/*.pb.go

# Docker build (opcional, para teste local).
docker:
	docker build -t crias-agent:dev .
