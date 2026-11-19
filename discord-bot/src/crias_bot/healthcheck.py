"""Docker healthcheck for crias-bot (CR-22).

The bot's heartbeat task (see ``bot.py``) writes a wall-clock timestamp to
``HEARTBEAT_PATH`` every 30s while it is connected to Discord. This script
exits 0 when the file exists and is fresh, 1 otherwise — so the container
healthcheck validates the *running bot* (gateway connected, event loop
alive), not just that the dependencies import.

Run with::

    python -m crias_bot.healthcheck

Standalone on purpose (stdlib only, no discord/grpc imports) so it works
even with a broken environment. Import-safe: importing this module has no
side effects — unit tests import :func:`check_heartbeat` directly.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

# Keep in sync with bot.py (the writer).
HEARTBEAT_PATH = Path("/tmp/crias-bot-heartbeat")
# The heartbeat ticks every 30s; 120s tolerates a few missed ticks (busy
# event loop, transient FS hiccup) without masking a real hang.
HEARTBEAT_MAX_AGE_SECONDS = 120.0


def check_heartbeat(
    path: Path | str | None = None,
    *,
    max_age: float = HEARTBEAT_MAX_AGE_SECONDS,
    now: float | None = None,
) -> tuple[bool, str]:
    """Return ``(healthy, message)`` for the heartbeat file at ``path``.

    ``path=None`` resolves to the module-level ``HEARTBEAT_PATH`` at call
    time (so tests can monkeypatch it). ``now`` allows injecting the
    current time.
    """
    if path is None:
        path = HEARTBEAT_PATH
    try:
        raw = Path(path).read_text(encoding="utf-8").strip()
    except OSError as e:
        return False, f"arquivo de heartbeat indisponível: {e}"
    try:
        ts = float(raw)
    except ValueError:
        return False, f"conteúdo de heartbeat inválido: {raw[:40]!r}"
    age = (time.time() if now is None else now) - ts
    if age < 0:
        # Wall clock jumped backwards (NTP); treat as fresh, not stale.
        age = 0.0
    if age > max_age:
        return False, f"heartbeat obsoleto: {age:.0f}s (máx {max_age:.0f}s)"
    return True, f"heartbeat ok ({age:.0f}s)"


def main() -> int:
    """CLI entry point: exit 0 when healthy, 1 with a stderr message otherwise."""
    healthy, msg = check_heartbeat()
    if not healthy:
        print(f"crias-bot healthcheck FAIL: {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
