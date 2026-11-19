"""Bot entry point.

Run with: python -m crias_bot, python -m discord-bot, or poetry run crias-bot.
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
        tls_ca_path=cfg.agent_tls_ca_path,
        use_tls=cfg.agent_use_tls,
    )

    bot = CriasBot(cfg, agent)

    try:
        asyncio.run(_run(bot, cfg.discord_token))
    except KeyboardInterrupt:
        log.info("Interrompido pelo usuário")


async def _run(bot: CriasBot, token: str) -> None:
    """Start the Discord bot first; connect to the gRPC agent in background.

    O bot DEVE ficar online mesmo com o agente indisponivel (CR-11): o
    connect() antigo era awaited antes do bot.start e, como ele retry-a
    forever para falhas transitórias, um agente offline mantinha o bot fora
    do Discord indefinidamente. Comandos que dependem do agente reportam
    "agente offline" ate a conexao estabelecer (stub None guard).
    """
    log = logging.getLogger("crias-bot")

    log.info("Iniciando bot Discord ...")
    async with bot:
        agent_task = asyncio.create_task(_connect_agent_forever(bot))
        try:
            await bot.start(token)
        finally:
            agent_task.cancel()
            try:
                await agent_task
            except asyncio.CancelledError:
                pass


async def _connect_agent_forever(bot: CriasBot) -> None:
    """Supervised agent connection; connect() itself retries with backoff."""
    log = logging.getLogger("crias-bot")
    log.info("Conectando ao agente em %s ...", bot.config.agent_host)
    try:
        await bot.agent.connect()
        log.info("Conectado ao agente.")
    except Exception as e:  # pragma: no cover - defensive: connect() should retry
        log.error("Conexao com o agente terminou com erro: %s", e)


if __name__ == "__main__":
    main()
