#!/usr/bin/env python3
"""Linux controlling-PTY checks and observational baseline for the experimental Hub."""
from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import math
import os
import pty
import select
import signal
import statistics
import struct
import termios
import time
from pathlib import Path

LIMIT = 512 * 1024
TIMEOUT = 12
ENTER_ALT = b"\x1b[?1049h"
LEAVE_ALT = b"\x1b[?1049l"


class Session:
    def __init__(self, binary: Path, term: str = "xterm-256color",
                 width: int = 120, height: int = 40,
                 ascii_mode: bool = True, no_color: bool = True,
                 telemetry: bool = False) -> None:
        self.master, self.slave = pty.openpty()
        self.original = termios.tcgetattr(self.slave)
        self.output = b""
        self.status = None
        self.start_ns = time.monotonic_ns()
        self.resize(width, height)
        self.pid = os.fork()
        if self.pid == 0:
            try:
                os.close(self.master)
                os.setsid()
                fcntl.ioctl(self.slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(self.slave, fd)
                if self.slave > 2:
                    os.close(self.slave)
                env = {"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "TERM": term}
                if ascii_mode:
                    env["CRIAS_HUB_ASCII"] = "1"
                if no_color:
                    env["NO_COLOR"] = "1"
                args = [str(binary)] + (["--telemetry"] if telemetry else [])
                os.execve(str(binary), args, env)
            except BaseException:
                os._exit(127)

    def resize(self, width: int, height: int) -> None:
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))

    def poll(self) -> int | None:
        if self.status is None:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
        return self.status

    def read(self, timeout: float) -> None:
        if self.master < 0 or not select.select([self.master], [], [], max(0, timeout))[0]:
            return
        try:
            chunk = os.read(self.master, 8192)
        except OSError as exc:
            if exc.errno != errno.EIO:
                raise
            return
        self.output += chunk
        if len(self.output) > LIMIT:
            raise RuntimeError("PTY output limit exceeded")

    def expect(self, marker: bytes, after: int = 0) -> None:
        deadline = time.monotonic() + TIMEOUT
        while marker not in self.output[after:]:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"missing {marker!r}; tail={self.output[-400:]!r}")
            if self.poll() is not None:
                self.read(0)
                if marker not in self.output[after:]:
                    raise RuntimeError(f"exited {self.status} before {marker!r}")
            self.read(min(0.1, deadline-time.monotonic()))

    def ready(self) -> float:
        self.expect(b"CRIAS HUB")
        self.expect(b"Visao geral")
        self.expect(ENTER_ALT)
        if termios.tcgetattr(self.slave) == self.original:
            raise RuntimeError("interactive terminal never changed mode")
        return (time.monotonic_ns()-self.start_ns)/1e6

    def key(self, key: bytes, marker: bytes) -> float:
        offset = len(self.output)
        start = time.monotonic_ns()
        os.write(self.master, key)
        self.expect(marker, offset)
        return (time.monotonic_ns()-start)/1e6

    def finish(self, allowed: tuple[int, ...], restore: bool = True) -> None:
        deadline = time.monotonic()+TIMEOUT
        while self.poll() is None:
            if time.monotonic() >= deadline:
                raise TimeoutError("prototype did not exit")
            self.read(0.05)
            time.sleep(0.005)
        if self.master >= 0:
            # Parent keeps slave open for termios inspection, so no EOF is
            # expected here. Drain queued output without blocking.
            while select.select([self.master], [], [], 0)[0]:
                before = len(self.output)
                self.read(0)
                if len(self.output) == before:
                    break
        if self.status not in allowed:
            raise RuntimeError(f"unexpected exit status {self.status}")
        if restore:
            if termios.tcgetattr(self.slave) != self.original:
                raise RuntimeError("termios not restored")
            if LEAVE_ALT not in self.output:
                raise RuntimeError("alternate screen not restored")

    def close(self) -> None:
        if self.poll() is None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                os.kill(self.pid, signal.SIGKILL)
            _, status = os.waitpid(self.pid, 0)
            self.status = os.waitstatus_to_exitcode(status)
        if self.master >= 0:
            os.close(self.master)
            self.master = -1
        os.close(self.slave)

    def __enter__(self) -> Session:
        return self

    def __exit__(self, *_args) -> None:
        self.close()


def lifecycle(binary: Path) -> None:
    with Session(binary) as s:
        s.ready()
        s.key(b"2", b"Servidores")
        s.key(b"\r", b"Nenhuma operacao administrativa")
        # Esc leaves detail, not application. Subsequent navigation proves it.
        os.write(s.master, b"\x1b")
        time.sleep(0.15)
        s.key(b"3", b"Hardware")
        s.resize(20, 5)
        s.key(b"4", b"Backups")
        s.resize(80, 24)
        s.key(b"5", b"Sistema")
        os.write(s.master, b"q")
        s.finish((0,))
    print("PASS: navigation, detail, Esc, resize, Q and terminal restoration")
    with Session(binary) as s:
        s.ready()
        s.key(b"/", b"Busca")
        s.key(b"ram", b"ram")
        s.key(b"\r", b"Hardware")
        s.key(b"?", b"Ajuda")
        os.write(s.master, b"q6")
        time.sleep(0.15)
        if s.poll() is not None:
            raise RuntimeError("global shortcuts leaked into help")
        os.write(s.master, b"\x1b")
        time.sleep(0.15)
        s.key(b"4", b"Backups")
        os.write(s.master, b"q")
        s.finish((0,))
    print("PASS: search navigation, help isolation and terminal restoration")
    with Session(binary) as s:
        s.ready()
        s.key(b"\x1b[17~", b"udo")  # F6 -> Conteudo
        s.key(b"\x1b[17~", b"xto")  # F6 -> Contexto
        s.key(b"\x1bOQ", b"udo")     # F2 -> hide context, focus Conteudo
        s.key(b"/", b"Busca")
        s.key(b"\x1b", b"udo")       # Esc -> restore prior focus
        os.write(s.master, b"q")
        s.finish((0,))
    print("PASS: F6 focus, F2 context toggle and search focus restoration")
    for terminal, width, height, ascii_mode, no_color in [
        ("xterm-256color", 100, 30, False, False),
        ("xterm-256color", 80, 24, False, True),
        ("linux", 60, 20, True, False),
        ("xterm-256color", 40, 15, True, True),
    ]:
        with Session(binary, term=terminal, width=width, height=height,
                     ascii_mode=ascii_mode, no_color=no_color) as s:
            s.expect(b"CRIAS HUB")
            s.expect(b"Visao geral" if ascii_mode else "Visão geral".encode())
            s.expect(ENTER_ALT)
            s.key(b"2", b"Servidores")
            os.write(s.master, b"q")
            s.finish((0,))
        print(f"PASS: PTY {terminal} {width}x{height} ascii={ascii_mode} no_color={no_color}")
    for key, label in [(b"\x1b", "Esc"), (b"\x03", "Ctrl+C")]:
        with Session(binary) as s:
            s.ready()
            os.write(s.master, key)
            s.finish((0,))
        print(f"PASS: {label} and terminal restoration")
    for sig in (signal.SIGTERM, signal.SIGHUP):
        with Session(binary) as s:
            s.ready()
            os.kill(s.pid, sig)
            # Context cancellation may intentionally return 1; signals must
            # not kill the process before it restores the terminal.
            s.finish((0, 1))
        print(f"PASS: {sig.name} and terminal restoration")
    with Session(binary, term="dumb") as s:
        s.finish((2,), restore=False)
        if ENTER_ALT in s.output or termios.tcgetattr(s.slave) != s.original:
            raise RuntimeError("dumb terminal was altered")
    print("PASS: TERM=dumb rejected without terminal mutation")
    with Session(binary) as s:
        s.ready()
        os.close(s.master)
        s.master = -1
        # A real hangup destroys the usable terminal; only bounded process
        # exit can be checked after closing the master.
        s.finish((0, 1), restore=False)
    print("PASS: PTY hangup exits without orphaned session leader")
    with Session(binary, telemetry=True) as s:
        s.ready()
        s.expect(b"RAM host:")
        s.expect(b"MiB")
        s.key(b"3", b"Hardware")
        os.write(s.master, b"q")
        s.finish((0,))
    print("PASS: opt-in host telemetry, navigation and terminal restoration")
    with Session(binary, telemetry=True) as s:
        s.ready()
        s.key(b"6", b"Monitoramento:")
        s.key(b"p", b"Economico")
        s.key(b"?", b"Ajuda")
        os.write(s.master, b"pp")
        s.key(b"\x1b", b"Monitoramento: Economico")
        s.key(b"1", b"Historico 1 min")
        # The renderer can emit only a changed digit; switch away and back
        # to observe the entire history label after the key.
        os.write(s.master, b"h")
        s.key(b"2", b"Recursos ainda nao conectados.")
        s.key(b"1", b"Historico 5 min")
        s.key(b"3", b"Enter: detalhes de hardware")
        s.key(b"\r", b"Capacidades de leitura")
        # Observe the new page digit as a synchronization marker, then
        # force a compact/full layout transition to assert the whole title.
        s.key(b"\x1b[B", b"2")
        offset = len(s.output)
        s.resize(40, 15)
        s.expect(b"Nenhuma operacao administrativa", offset)
        offset = len(s.output)
        s.resize(120, 40)
        s.expect(b"Hardware 2/", offset)
        s.key(b"\x1b", b"Enter: detalhes de hardware")
        s.key(b"5", b"Servicos systemd")
        os.write(s.master, b"q")
        s.finish((0,))
    print("PASS: telemetry profile, help isolation, history, hardware pages, resize and system view")


def process_snapshot(pid: int) -> tuple[int, int]:
    raw = Path(f"/proc/{pid}/stat").read_text()
    fields = raw[raw.rfind(")")+2:].split()
    ticks = int(fields[11])+int(fields[12])
    rss = int(fields[21])*os.sysconf("SC_PAGE_SIZE")//1024
    return ticks, rss


def summary(values: list[float]) -> dict:
    ordered = sorted(values)
    return {"count": len(ordered), "median": statistics.median(ordered),
            "p95_nearest_rank": ordered[math.ceil(len(ordered)*0.95)-1],
            "max": ordered[-1]}


def benchmark(binary: Path, count: int, idle_seconds: float) -> dict:
    rows = []
    for i in range(count):
        with Session(binary) as s:
            startup = s.ready()
            ticks, rss = process_snapshot(s.pid)
            idle = None
            if i == 0 and idle_seconds:
                before = len(s.output)
                started = time.monotonic()
                while time.monotonic()-started < idle_seconds:
                    s.read(min(0.1, idle_seconds-(time.monotonic()-started)))
                elapsed = time.monotonic()-started
                end_ticks, _ = process_snapshot(s.pid)
                idle = {"seconds": elapsed, "bytes": len(s.output)-before,
                        "cpu_percent_one_core": (end_ticks-ticks)/os.sysconf("SC_CLK_TCK")/elapsed*100}
            navigation = [s.key(b"2", b"Servidores"), s.key(b"1", b"Visao geral")]
            os.write(s.master, b"q")
            s.finish((0,))
            rows.append({"startup_ms": startup, "navigation_ms": navigation,
                         "rss_main_kib": rss, "pty_bytes_observed": len(s.output), "idle": idle})
    return {"schema": 1, "mode": "hub-presentation-only",
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "binary_bytes": binary.stat().st_size,
            "kernel": os.uname().release, "architecture": os.uname().machine,
            "terminal": "controlling PTY 120x40 xterm-256color NO_COLOR",
            "limitations": "No host discovery, game load or SSH; label observation not full render. Go tab switches differ from Bash submenu transitions. ASCII/no-color test mode. RSS is main process, not session PSS. Short idle sample, observational only.",
            "startup_ms": summary([r["startup_ms"] for r in rows]),
            "navigation_ms": summary([v for r in rows for v in r["navigation_ms"]]),
            "rss_main_kib": summary([r["rss_main_kib"] for r in rows]),
            "samples": rows}


# C03 measurements preserve the C01 report and separately compare modes.
# Linux stat accounts for waited children, not children still running.
def telemetry_process(pid: int) -> dict:
    raw = Path(f"/proc/{pid}/stat").read_text()
    fields = raw[raw.rfind(")")+2:].split()
    pss = None
    try:
        for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            if line.startswith("Pss:"):
                pss = int(line.split()[1])
                break
    except OSError:
        pass
    return {
        "main_ticks": int(fields[11])+int(fields[12]),
        "waited_child_ticks": int(fields[13])+int(fields[14]),
        "rss_kib": int(fields[21])*os.sysconf("SC_PAGE_SIZE")//1024,
        "pss_kib": pss,
    }


def select_profile(session: Session, mode: str) -> None:
    if mode == "static":
        return
    session.key(b"6", b"Monitoramento: Balanceado")
    if mode in ("economy", "detailed"):
        session.key(b"p", b"Economico")
    if mode == "detailed":
        session.key(b"p", b"Detalhado")
    session.key(b"1", b"Historico 1 min")


def drain_window(session: Session, seconds: float, sample_memory: bool) -> dict:
    # Bound the captured transcript independently of window duration.
    # The final exit still checks the alternate-screen leave sequence.
    session.output = b""
    initial = telemetry_process(session.pid)
    samples = [initial]
    byte_count = 0
    started = time.monotonic()
    next_sample = started + 1
    while time.monotonic()-started < seconds:
        if session.poll() is not None:
            raise RuntimeError("Hub exited during idle measurement")
        session.read(min(0.1, max(0, seconds-(time.monotonic()-started))))
        byte_count += len(session.output)
        session.output = b""
        if sample_memory and time.monotonic() >= next_sample:
            samples.append(telemetry_process(session.pid))
            next_sample = time.monotonic()+1
    elapsed = time.monotonic()-started
    final = telemetry_process(session.pid)
    samples.append(final)
    hz = os.sysconf("SC_CLK_TCK")
    pss = [s["pss_kib"] for s in samples if s["pss_kib"] is not None]
    main = final["main_ticks"]-initial["main_ticks"]
    children = final["waited_child_ticks"]-initial["waited_child_ticks"]
    if main < 0 or children < 0:
        raise RuntimeError("invalid CPU counters")
    return {
        "seconds": elapsed,
        "cpu_main_percent_one_core": 100*main/hz/elapsed,
        "cpu_waited_children_percent_one_core": 100*children/hz/elapsed,
        "pty_bytes": byte_count,
        "rss_kib": summary([s["rss_kib"] for s in samples]),
        "pss_kib": summary(pss) if pss else None,
        "pss_missing_samples": len(samples)-len(pss),
        "rss_delta_kib": final["rss_kib"]-initial["rss_kib"],
    }


def compare_telemetry(binary: Path, count: int, idle_seconds: float, warmup_seconds: float) -> dict:
    modes = ("static", "balanced", "economy", "detailed")
    results = {mode: [] for mode in modes}
    # Rotate mode order to reduce systematic host drift between trials.
    for trial in range(count):
        for mode in modes[trial % len(modes):]+modes[:trial % len(modes)]:
            with Session(binary, telemetry=mode != "static") as session:
                startup = session.ready()
                ready_ms = None
                if mode != "static":
                    session.expect(b"MiB")
                    ready_ms = (time.monotonic_ns()-session.start_ns)/1e6
                select_profile(session, mode)
                idle = None
                if trial == 0:
                    drain_window(session, warmup_seconds, False)
                    idle = drain_window(session, idle_seconds, True)
                navigation = [session.key(b"2", b"Recursos ainda nao conectados."),
                              session.key(b"1", b"Area: Visao geral")]
                os.write(session.master, b"q")
                session.finish((0,))
                results[mode].append({"startup_ms": startup, "first_ram_ms": ready_ms,
                                      "navigation_ms": navigation, "idle": idle})
    return {
        "schema": 1, "mode": "hub-telemetry-comparison",
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "binary_bytes": binary.stat().st_size,
        "kernel": os.uname().release, "architecture": os.uname().machine,
        "cpu_count": os.cpu_count(), "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
        "terminal": "controlling PTY 120x40 xterm-256color NO_COLOR",
        "warmup_seconds": warmup_seconds, "idle_seconds_requested": idle_seconds,
        "limitations": "Startup is initial static/default-balanced render; other profiles are selected after startup. Navigation observes markers, not full frames. Idle has one observation per mode, main process RSS/PSS only, waited-child CPU excludes running children at boundaries. No game load, physical host, SSH or long-run leak conclusion. Shared runner; observational, no absolute performance gate.",
        "modes": {
            mode: {
                "startup_ms": summary([r["startup_ms"] for r in rows]),
                "first_ram_ms": summary([r["first_ram_ms"] for r in rows]) if mode != "static" else None,
                "navigation_ms": summary([v for r in rows for v in r["navigation_ms"]]),
                "idle": rows[0]["idle"], "samples": rows,
            } for mode, rows in results.items()
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--samples", type=int, default=30)
    parser.add_argument("--idle-seconds", type=float, default=5)
    parser.add_argument("--compare-telemetry", action="store_true")
    parser.add_argument("--warmup-seconds", type=float, default=15)
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("run as a non-root test user")
    if not 1 <= args.samples <= 100 or not math.isfinite(args.idle_seconds) or not 0 <= args.idle_seconds <= 600:
        parser.error("invalid sample count or idle duration")
    if not math.isfinite(args.warmup_seconds) or not 0 <= args.warmup_seconds <= 600:
        parser.error("invalid warmup duration")
    if args.compare_telemetry and args.idle_seconds < 1:
        parser.error("comparison requires positive idle duration")
    binary = args.binary.resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        parser.error("trusted Hub executable required")
    if args.compare_telemetry:
        report = compare_telemetry(binary, args.samples, args.idle_seconds, args.warmup_seconds)
        print("HUB_C03_PTY_JSON=" + json.dumps(report, separators=(",", ":"), allow_nan=False))
        return
    lifecycle(binary)
    report = benchmark(binary, args.samples, args.idle_seconds)
    print("HUB_C01_PTY_JSON=" + json.dumps(report, separators=(",", ":"), allow_nan=False))


if __name__ == "__main__":
    main()
