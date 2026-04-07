# Guia do Chunky - Pré-geração de Chunks

## O que é
Chunky é uma ferramenta de pré-geração de chunks do mundo.

## Por que usar
- Gera chunks ANTES dos jogadores chegarem
- Elimina o "lag de geração" quando os jogadores exploram
- Reduz quedas drásticas de TPS em servidores com pouco processamento

## Como usar
Via console (ou In-Game se você for OP):
1. **Definir centro:** `chunky center 0 0`
2. **Definir raio (blocos):** `chunky radius 2000`
3. **Iniciar geração:** `chunky start`
4. **Pausar geração:** `chunky pause`
5. **Ver progresso:** `chunky status`

## Como usar via Alias
No console SSH da máquina hospedeira, digite:
```bash
mcchunky
```
Isso abrirá um menu interativo permitindo que você inicie, paralise, verifique o status ou defina as áreas pelo painel.