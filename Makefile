# Crias-Server — runner unificado de testes (CR-29).
#
# O tests/run-all.sh cobre apenas a bateria Bash; os testes de Go e Python
# vivem em jobs separados da CI. Este Makefile reproduz a CI completa em uma
# unica entrada, com pre-requisitos explicitos por alvo.

.PHONY: help test-bash test-go test-python test-all lint-bash lint-go lint-python

help:
	@echo "Crias-Server — alvos de teste:"
	@echo "  test-bash    Bateria Bash completa (tests/run-all.sh)"
	@echo "  test-go      Testes do agente Go (discord-agent)"
	@echo "  test-python  Testes do bot Python (discord-bot, pytest)"
	@echo "  test-all     Tudo acima (equivale aos jobs de test da CI)"
	@echo "  lint-bash    shellcheck nos scripts do repo (se disponivel)"
	@echo "  lint-go      go vet + gofmt check (discord-agent)"
	@echo "  lint-python  ruff check + format check (discord-bot)"

# --- Bash: bash + coreutils + tar + zstd + flock + ionice (+ gettext p/
# envsubst-test). Sem root; nao precisa de systemd rodando (usa systemd-analyze
# apenas quando disponivel). ---
test-bash:
	bash tests/run-all.sh

# --- Go: go >= 1.26 (ver discord-agent/go.mod). ---
test-go:
	cd discord-agent && go build ./... && go vet ./... && go test ./...

# --- Python: python >= 3.11 + deps de discord-bot/requirements.txt + pytest. ---
test-python:
	cd discord-bot && python3 -m pytest tests/ -q

test-all: test-bash test-go test-python
	@echo "OK: bateria completa (bash + go + python)"

lint-bash:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck nao instalado (apt/pacman)"; exit 1; }
	shellcheck --severity error install.sh crias-bootstrap.sh shared/lib/*.sh minecraft/*.sh terraria/*.sh tests/*.sh

lint-go:
	cd discord-agent && go vet ./... && test -z "$$(gofmt -l .)"

lint-python:
	cd discord-bot && python3 -m ruff check src/ tests/ && python3 -m ruff format --check src/ tests/
