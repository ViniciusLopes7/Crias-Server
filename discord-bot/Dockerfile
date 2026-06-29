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
#
# Nota histórica: versões anteriores usavam `pip install --user` (que coloca
# pacotes em /root/.local) combinado com `USER 1001` no runtime. Isso causava
# ModuleNotFoundError porque /root tem perms 700 (inacessível ao user 1001)
# e o Python só procura em ~/.local baseado na HOME do usuário atual.
# A solução correta é usar um venv isolado em /opt/venv.

# --- Stage 1: builder ---
FROM python:3.12-slim AS builder

WORKDIR /app

# Dependências de build (grpcio precisa de gcc).
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Cria virtualenv isolado em /opt/venv (não depende de HOME/USER no runtime).
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
ENV VIRTUAL_ENV=/opt/venv

# Instala dependências primeiro (cache-friendly).
COPY discord-bot/pyproject.toml discord-bot/requirements.txt ./
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt

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

# Copia venv (completamente isolado de HOME/USER).
COPY --from=builder /opt/venv /opt/venv

# Copia código fonte do bot.
COPY --from=builder /app/src /app/src

# Ativa venv via PATH. PYTHONPATH aponta para o código do bot.
ENV PATH=/opt/venv/bin:$PATH
ENV VIRTUAL_ENV=/opt/venv
ENV PYTHONPATH=/app/src
# Garante que logs Python vão direto para stdout (Railway captura).
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Cria usuário não-root e ajusta permissões do venv e do código.
# Usuário 1001 é o padrão do Railway; alinhamos perms para evitar EACCES.
RUN groupadd --system --gid 1001 crias \
    && useradd --system --uid 1001 --gid crias --create-home --home-dir /home/crias crias \
    && chown -R 1001:1001 /app /opt/venv

USER 1001

# Healthcheck simples: tenta importar grpc e discord (valida venv + PYTHONPATH).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import grpc, discord; print('ok')" || exit 1

CMD ["python", "-m", "crias_bot"]
