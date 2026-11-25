#!/usr/bin/env python3
"""Observe real legacy Gum menus with a controlling PTY; Linux, non-root only.

Never installs packages or invokes administrative actions. No physical-host,
SSH or game-load claims. The renderer must actually emit both expected labels.
"""
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
import pty
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import termios
import time
from pathlib import Path

MAX_FRAME = 256 * 1024
ESCAPES = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")
BOOTSTRAP = r"""
source "$1"
hub_ensure_gum() { :; }
sudo() { echo 'BENCHMARK: forbidden administrative operation' >&2; exit 90; }
pacman() { echo 'BENCHMARK: forbidden package operation' >&2; exit 91; }
# Keep the real hub_choose and hub_gum_interactive.
if [ "$2" = fixture ]; then
    BENCH_STACK="$3"
    detect_stack() { printf '%s\n' "$BENCH_STACK"; }
    systemctl() { [ "$1" = is-active ]; }
fi
main
"""


def stats(values: list[float]) -> dict:
    values = sorted(values)
    return {"count": len(values), "median": statistics.median(values),
            "p95_nearest_rank": values[math.ceil(len(values)*0.95)-1], "max": values[-1]}


class Terminal:
    def __init__(self, fd: int, timeout: float) -> None:
        self.fd = fd
        self.timeout = timeout
        self.bytes = 0

    def read(self, timeout: float) -> bytes:
        if not select.select([self.fd], [], [], max(0, timeout))[0]:
            return b""
        try:
            chunk = os.read(self.fd, 8192)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            raise EOFError("PTY closed") from exc
        if not chunk:
            raise EOFError("PTY closed")
        self.bytes += len(chunk)
        return chunk

    def frame(self, header: bytes, last: bytes) -> float:
        start = time.monotonic_ns()
        deadline = time.monotonic() + self.timeout
        data = b""
        while time.monotonic() < deadline:
            data += self.read(deadline-time.monotonic())
            if len(data) > MAX_FRAME:
                raise RuntimeError("unexpected frame output exceeds limit")
            plain = ESCAPES.sub(b"", data)
            if b"modo numerado" in plain:
                raise RuntimeError("Gum route fell back to numeric menu")
            if b"forbidden" in plain:
                raise RuntimeError("unexpected administrative operation")
            index = plain.find(header)
            if index >= 0 and last in plain[index+len(header):]:
                return (time.monotonic_ns()-start)/1e6
        raise TimeoutError("expected real Gum frame not observed")

    def idle(self, seconds: float) -> int:
        start = self.bytes
        deadline = time.monotonic()+seconds
        while time.monotonic() < deadline:
            self.read(deadline-time.monotonic())
        return self.bytes-start


def session_snapshot(sid: int) -> dict:
    """Use process identity (PID, start ticks) to reject reuse/turnover."""
    rows = {}
    pagesize = os.sysconf("SC_PAGE_SIZE")
    for path in Path("/proc").iterdir():
        if not path.name.isdigit():
            continue
        try:
            raw = (path/"stat").read_text()
            # comm may contain spaces/parentheses; final ')' ends it.
            fields = raw[raw.rfind(")")+2:].split()
            if int(fields[3]) != sid:
                continue
            key = (int(path.name), int(fields[19]))
            rows[key] = (int(fields[11])+int(fields[12]),
                         int(fields[21])*pagesize//1024)
        except (OSError, ValueError, IndexError):
            continue
    if not any(pid == sid for pid, _ in rows):
        raise RuntimeError("benchmark session leader not observable")
    return rows


def sample(hub: Path, mode: str, stack: str, timeout: float, idle: float,
           trusted_path: str = "/usr/bin:/bin", no_color: bool = False) -> dict:
    # pty.fork creates a controlling TTY; openpty alone is insufficient for
    # Gum versions which open /dev/tty. Child sets size before exec.
    env = {"PATH": trusted_path, "LANG": "C.UTF-8", "TERM": "xterm-256color"}
    if no_color:
        env["NO_COLOR"] = "1"
    started = time.monotonic_ns()
    pid, fd = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
            os.execve("/bin/bash", ["/bin/bash", "--noprofile", "--norc", "-c",
                      BOOTSTRAP, "gum-baseline", str(hub), mode, stack], env)
        except BaseException:
            os._exit(127)
    terminal = Terminal(fd, timeout)
    reaped = False
    try:
        terminal.frame(b"Menu principal", b"Sair")
        startup = (time.monotonic_ns()-started)/1e6
        first = session_snapshot(pid)
        idle_report = None
        if idle > 0:
            begin = time.monotonic()
            idle_bytes = terminal.idle(idle)
            end = time.monotonic()
            second = session_snapshot(pid)
            # Membership changes make CPU delta incomplete; never report zero
            # for an unavailable measurement.
            same = set(first) == set(second)
            ticks = sum(second[k][0]-first[k][0] for k in first) if same else None
            idle_report = {"seconds": end-begin, "bytes": idle_bytes,
                           "stable_membership": same,
                           "cpu_percent_one_core": ticks/os.sysconf("SC_CLK_TCK")/(end-begin)*100
                           if ticks is not None and ticks >= 0 else None}
        # First item is "Servidor" for both legacy stacks. Abort on any
        # unexpected screen; sudo and pacman are additionally blocked.
        t = time.monotonic_ns()
        os.write(fd, b"\r")
        terminal.frame("Servidor —".encode("utf-8"), b"Voltar")
        enter = (time.monotonic_ns()-t)/1e6
        t = time.monotonic_ns()
        os.write(fd, b"\x1b")
        terminal.frame(b"Menu principal", b"Sair")
        back = (time.monotonic_ns()-t)/1e6
        os.write(fd, b"\x1b")
        deadline = time.monotonic()+timeout
        while time.monotonic() < deadline:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                reaped = True
                if os.waitstatus_to_exitcode(status) != 0:
                    raise RuntimeError("Hub exited unsuccessfully")
                return {"startup_ms": startup, "navigation_ms": [enter, back],
                        "session_rss_sum_kib": sum(v[1] for v in first.values()),
                        "session_processes_at_first_frame": len(first),
                        "pty_bytes_observed": terminal.bytes,
                        "idle": idle_report}
            try:
                terminal.read(min(0.1, deadline-time.monotonic()))
            except EOFError:
                time.sleep(0.01)
        raise TimeoutError("Hub did not exit after Esc")
    finally:
        if not reaped:
            # PID is the isolated PTY session/group leader; never kill a host
            # service or an arbitrary process selected from user input.
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
        os.close(fd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", type=Path, default=Path(__file__).resolve().parents[1]/"crias-tui.sh")
    parser.add_argument("--mode", choices=["host", "fixture"], default="fixture")
    parser.add_argument("--stack", choices=["minecraft", "terraria"], default="minecraft")
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--idle-seconds", type=float, default=0,
                        help="observe first sample only; 0 disables, maximum 600")
    parser.add_argument("--gum-dir", type=Path,
                        help="explicit trusted directory containing executable gum; no installation")
    parser.add_argument("--no-color", action="store_true", help="match NO_COLOR test environment")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("run as a non-root test/admin account")
    if not (1 <= args.samples <= 100 and math.isfinite(args.timeout) and
            0 < args.timeout <= 60 and math.isfinite(args.idle_seconds) and
            0 <= args.idle_seconds <= 600):
        parser.error("invalid samples, timeout or idle duration")
    trusted_path = "/usr/bin:/bin"
    if args.gum_dir is not None:
        directory = args.gum_dir.resolve(strict=True)
        if ":" in str(directory) or not (directory / "gum").is_file() or not os.access(directory / "gum", os.X_OK):
            parser.error("--gum-dir must contain a trusted executable gum")
        trusted_path = str(directory) + ":" + trusted_path
    gum = shutil.which("gum", path=trusted_path)
    if gum is None:
        parser.error("healthy Gum must already be installed; no auto-install")
    hub = args.hub.resolve(strict=True)
    if not hub.is_file():
        parser.error("use a trusted legacy Hub script")
    try:
        version_result = subprocess.run([gum, "--version"], check=True, capture_output=True,
                                 text=True, timeout=5,
                                 env={"PATH": trusted_path, "LANG": "C.UTF-8"})
        version = (version_result.stdout or version_result.stderr).strip()
        if not version:
            raise RuntimeError("Gum version not identifiable")
        rows = [sample(hub, args.mode, args.stack, args.timeout,
                       args.idle_seconds if i == 0 else 0, trusted_path, args.no_color)
                for i in range(args.samples)]
    except (OSError, RuntimeError, EOFError, TimeoutError, subprocess.SubprocessError) as exc:
        parser.exit(1, f"Gum benchmark failed: {exc}\n")
    print(json.dumps({
        "schema": 1, "mode": args.mode,
        "stack": args.stack if args.mode == "fixture" else "auto-detected",
        "hub_sha256": hashlib.sha256(hub.read_bytes()).hexdigest(),
        "gum_version": version, "gum_sha256": hashlib.sha256(Path(gum).read_bytes()).hexdigest(),
        "no_color": args.no_color, "kernel": os.uname().release,
        "architecture": os.uname().machine, "terminal": "controlling PTY 120x40, xterm-256color",
        "limitations": "Frame labels, not pixel-render completion; local PTY only, no SSH/game load. RSS sum counts shared pages multiple times. Idle CPU is available only with stable session membership and is observational. PTY bytes are not network traffic.",
        "startup_ms": stats([s["startup_ms"] for s in rows]),
        "navigation_ms": stats([v for s in rows for v in s["navigation_ms"]]),
        "session_rss_sum_kib": stats([s["session_rss_sum_kib"] for s in rows]),
        "samples": rows,
    }, indent=2, allow_nan=False))


if __name__ == "__main__":
    main()
