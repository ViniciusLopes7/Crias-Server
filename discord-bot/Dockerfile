# discord-bot/Dockerfile
#
# Imagem Python slim para Railway. Multi-stage para reduzir tamanho final.
#
# IMPORTANTE: o build context deve ser a raiz do repo (não discord-bot/)
# porque precisamos de discord-agent/proto/crias.proto.
#
# Build:
#   cd <repo-raiz>
#   docker build -t crias-bot:latest -f discord-bot/Dockerfile .

# --- Stage 1: builder ---
FROM python:3.12-slim AS builder

WORKDIR /app

# Dependências de build (grpcio precisa de gcc).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Instala dependências primeiro (cache-friendly).
COPY discord-bot/pyproject.toml discord-bot/requirements.txt ./
RUN pip install --no-cache-dir --user -r requirements.txt

# Copia código do bot.
COPY discord-bot/src/ ./src/

# Copia proto do agente (mesmo repo, dir diferente).
COPY discord-agent/proto/ ./proto/

# Gera código protobuf Python.
RUN mkdir -p ./src/crias_bot/grpc_gen \
    && python -m grpc_tools.protoc \
        -I ./proto \
        --python_out=./src/crias_bot/grpc_gen \
        --grpc_python_out=./src/crias_bot/grpc_gen \
        ./proto/crias.proto \
    && touch ./src/crias_bot/grpc_gen/__init__.py \
    && sed -i 's/^import crias_pb2 as crias__pb2/from crias_bot.grpc_gen import crias_pb2 as crias__pb2/' \
        ./src/crias_bot/grpc_gen/crias_pb2_grpc.py

# --- Stage 2: runtime ---
FROM python:3.12-slim

WORKDIR /app

# Copia dependências instaladas.
COPY --from=builder /root/.local /root/.local
COPY --from=builder /app/src /app/src

ENV PATH=/root/.local/bin:$PATH
ENV PYTHONPATH=/app/src

# Não roda como root em produção (Railway cuida do user, mas defensivo).
USER 1001

CMD ["python", "-m", "crias_bot"]
