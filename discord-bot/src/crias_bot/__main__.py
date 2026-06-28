"""Entry point do bot Discord.

Uso:
  python -m crias_bot        # via pyproject.toml [tool.poetry.scripts]
  python -m discord-bot      # direto
  poetry run crias-bot       # via Poetry
"""

from __future__ import annotations

import asyncio
import logging
import sys

from .agent_client import AgentClient
from .bot import CriasBot
from .config import load_config


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    log = logging.getLogger("crias-bot")

    try:
        cfg = load_config()
    except ValueError as e:
        log.error("Config inválida: %s", e)
        sys.exit(1)

    agent = AgentClient(
        host=cfg.agent_host,
        token=cfg.agent_token,
        max_reconnect_delay=cfg.reconnect_max_delay,
    )

    bot = CriasBot(cfg, agent)

    try:
        asyncio.run(_run(bot, cfg.discord_token))
    except KeyboardInterrupt:
        log.info("Interrompido pelo usuário")


async def _run(bot: CriasBot, token: str) -> None:
    """Conecta ao agente gRPC primeiro, depois inicia o bot Discord."""
    log = logging.getLogger("crias-bot")
    log.info("Conectando ao agente em %s ...", bot.config.agent_host)
    try:
        await bot.agent.connect()
    except Exception as e:
        log.error("Não foi possível conectar ao agente: %s", e)
        log.warning("Bot vai iniciar mesmo assim; vai tentar reconectar em background.")

    log.info("Iniciando bot Discord ...")
    async with bot:
        await bot.start(token)


if __name__ == "__main__":
    main()
