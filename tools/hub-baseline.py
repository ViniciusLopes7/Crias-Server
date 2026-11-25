#!/usr/bin/env python3
"""Measure the legacy numeric Hub in a PTY, without administrative actions.

Fixture mode simulates stack/status discovery; host mode uses real read-only
discovery. Neither mode measures Gum, SSH latency, idle CPU or game impact.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import math
import os
import pty
import resource
import select
import signal
import statistics
import subprocess
import termios
import time
from pathlib import Path

PROMPT = b"Escolha (numero ou nome, Enter para voltar): "
MAX_OUTPUT = 65536
BOOTSTRAP = r"""
source "$1"
# No package recovery, no privilege escalation, no real admin calls.
hub_ensure_gum() { :; }
hub_gum_interactive() { return 1; }
sudo() { echo 'BENCHMARK: forbidden admin operation' >&2; exit 90; }
pacman() { echo 'BENCHMARK: forbidden package operation' >&2; exit 91; }
if [ "$2" = fixture ]; then
    # A shell function's positional parameters are local: store stack first.
    BENCH_STACK="$3"
    detect_stack() { printf '%s\n' "$BENCH_STACK"; }
    systemctl() {
        if [ "$1" = is-active ]; then return 0; fi
        return 1
    }
fi
main
"""


def wait_prompt(fd: int, pending: bytes, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    while True:
        if PROMPT in pending:
            return pending.split(PROMPT, 1)[1]
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise TimeoutError("numeric menu prompt not received")
        try:
            block = os.read(fd, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                raise RuntimeError("Hub exited before the expected prompt") from exc
            raise
        if not block:
            raise RuntimeError("Hub closed the PTY before the expected prompt")
        pending += block
        if len(pending) > MAX_OUTPUT:
            raise RuntimeError("unexpected output exceeded benchmark limit")


def rss_kib(pid: int) -> int | None:
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def sample(hub: Path, mode: str, stack: str, timeout: float) -> dict:
    master, slave = pty.openpty()
    child = None
    try:
        attrs = termios.tcgetattr(slave)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, attrs)
        # Do not inherit BASH_ENV, exported functions or user-specific PATH.
        env = {"PATH": "/usr/bin:/bin", "LANG": "C", "TERM": "dumb"}
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        started = time.monotonic_ns()
        child = subprocess.Popen(
            ["/bin/bash", "--noprofile", "--norc", "-c", BOOTSTRAP,
             "hub-baseline", str(hub), mode, stack],
            stdin=slave, stdout=slave, stderr=slave,
            env=env, start_new_session=True,
        )
        os.close(slave)
        slave = -1
        pending = wait_prompt(master, b"", timeout)
        startup_ms = (time.monotonic_ns() - started) / 1e6
        first_rss = rss_kib(child.pid)
        navigation_ms = []
        for key in (b"1\n", b"\n"):
            started = time.monotonic_ns()
            os.write(master, key)
            pending = wait_prompt(master, pending, timeout)
            navigation_ms.append((time.monotonic_ns() - started) / 1e6)
        os.write(master, b"\n")  # exit main; no write operation selected
        if child.wait(timeout=timeout) != 0:
            raise RuntimeError(f"Hub exit status {child.returncode}")
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        return {
            "startup_ms": startup_ms,
            "navigation_ms": navigation_ms,
            "rss_at_first_prompt_kib": first_rss,
            "cpu_seconds_whole_sample": (
                after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime
            ),
        }
    finally:
        if slave >= 0:
            os.close(slave)
        if child is not None and child.poll() is None:
            # Kill the isolated benchmark process group, not host services.
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        os.close(master)


def summary(values: list[float]) -> dict:
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "median": statistics.median(ordered),
        "p95_nearest_rank": ordered[math.ceil(0.95 * len(ordered)) - 1],
        "max": ordered[-1],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", type=Path, default=Path(__file__).resolve().parents[1] / "crias-tui.sh")
    parser.add_argument("--mode", choices=("fixture", "host"), default="fixture")
    parser.add_argument("--stack", choices=("minecraft", "terraria"), default="minecraft",
                        help="fixture stack only; host mode discovers real stack")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    if not 1 <= args.samples <= 200 or not math.isfinite(args.timeout) or not 0 < args.timeout <= 60:
        parser.error("samples must be 1..200; timeout must be >0 and <=60 seconds")
    hub = args.hub.resolve(strict=True)
    if not hub.is_file():
        parser.error("--hub must be a trusted legacy Hub script")
    try:
        rows = [sample(hub, args.mode, args.stack, args.timeout) for _ in range(args.samples)]
    except (OSError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as exc:
        parser.exit(1, f"benchmark failed: {exc}\n")
    rss = [row["rss_at_first_prompt_kib"] for row in rows if row["rss_at_first_prompt_kib"] is not None]
    result = {
        "schema": 1,
        "mode": args.mode,
        "stack": args.stack if args.mode == "fixture" else "auto-detected",
        "hub_sha256": hashlib.sha256(hub.read_bytes()).hexdigest(),
        "kernel": os.uname().release,
        "architecture": os.uname().machine,
        "terminal": "PTY numeric fallback (TERM=dumb; no Gum)",
        "limitations": "No real admin calls, Gum, SSH, idle CPU or game performance; RSS is a point sample of the Bash process only; CPU includes the whole finite sample.",
        "startup_ms": summary([row["startup_ms"] for row in rows]),
        "navigation_ms": summary([v for row in rows for v in row["navigation_ms"]]),
        "rss_at_first_prompt_kib": summary(rss) if rss else None,
        "cpu_seconds_whole_sample": summary([row["cpu_seconds_whole_sample"] for row in rows]),
        "samples": rows,
    }
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
