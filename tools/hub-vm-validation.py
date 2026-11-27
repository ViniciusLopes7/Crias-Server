#!/usr/bin/env python3
"""VM validation for the opt-in Hub. No installation, sudo or service changes."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = {"quick": (3, 5, 2), "full": (30, 600, 15)}
MODES = ("static", "economy", "balanced", "detailed")
PIN = "go1.27.4"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def executable(path):
    path = Path(path).expanduser().resolve(strict=True)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ValueError("trusted executable required")
    return path


def report_from_log(path, prefix=None):
    text = path.read_text(encoding="utf-8")
    if prefix is None:
        return json.loads(text)
    rows = [row[len(prefix):] for row in text.splitlines() if row.startswith(prefix)]
    if len(rows) != 1:
        raise ValueError("missing or repeated benchmark marker")
    return json.loads(rows[0])


def telemetry_summary(data, binary_hash, count, idle):
    if (data.get("schema") != 2 or data.get("mode") != "hub-telemetry-comparison"
            or data.get("binary_sha256") != binary_hash
            or set(data.get("modes", {})) != set(MODES)):
        raise ValueError("unexpected telemetry report or binary identity")
    hz = data["clock_ticks_per_second"]
    if not isinstance(hz, int) or hz <= 0:
        raise ValueError("invalid tick rate")
    rows = {}
    for mode in MODES:
        v = data["modes"][mode]
        q = v["idle"]
        raw = q["raw_samples"]
        if (len(v["samples"]) != count or v["startup_ms"]["count"] != count
                or v["navigation_ms"]["count"] != 2 * count
                or q["seconds"] < idle or len(raw) != q["memory_sample_count"]
                or len(raw) < 2 or raw[0][:3] != [0, 0, 0]):
            raise ValueError("incomplete telemetry samples")
        for a, b in zip(raw, raw[1:]):
            if b[0] <= a[0] or b[1] < a[1] or b[2] < a[2]:
                raise ValueError("non-monotonic telemetry samples")
        last = raw[-1]
        cpu = 100 * (last[1] + last[2]) / hz / (last[0] / 1e9)
        if not math.isclose(cpu, q["cpu_main_plus_waited_percent_one_core"], abs_tol=1e-9):
            raise ValueError("CPU summary does not match raw ticks")
        rss = q["rss_kib"]["median"] / 1024
        startup = v["startup_ms"]["median"]
        navigation = v["navigation_ms"]["p95_nearest_rank"]
        size = data["binary_bytes"] / 1048576
        if not all(math.isfinite(n) and n >= 0 for n in (cpu, rss, startup, navigation, size)):
            raise ValueError("invalid metric")
        rows[mode] = {
            "cpu_percent_one_core": cpu, "rss_mib": rss,
            "pss_mib": q["pss_kib"]["median"] / 1024 if q["pss_kib"] else None,
            "startup_median_ms": startup, "navigation_p95_ms": navigation,
            "binary_mib": size, "idle_seconds": q["seconds"],
            "cpu_reference_met": cpu <= 0.5, "cpu_desirable_met": cpu <= 0.2,
            "other_references_met": rss <= 25 and startup <= 300 and navigation <= 50 and size <= 15,
            "other_desirable_met": rss <= 15 and startup <= 150 and navigation <= 20 and size <= 10,
        }
    return rows


class Suite:
    def __init__(self, out, args):
        self.out, self.args = out, args
        self.report = {
            "schema": 1, "mode": args.mode, "steps": [],
            "automatic_status": "INCOMPLETE", "manual_gates": {
                "installed_release_identity": "PENDING",
                "physical_sensors": "PENDING", "real_ssh": "PENDING",
                "controlled_repeated_cpu": "PENDING", "long_run_and_game_load": "PENDING",
            },
            "limitations": [
                "VM sensors are virtual or absent; not physical hardware validation.",
                "PTY measures markers, not complete frames or SSH network latency.",
                "CPU includes main and waited children, not complete process tree.",
                "Quick mode does not cover the slowest 45s service cadence.",
                "One idle window per mode; repeat full runs under controlled conditions.",
                "No automatic M2 approval; manual gates remain pending.",
            ],
        }

    def save(self):
        tmp = self.out / ".report.tmp"
        tmp.write_text(json.dumps(self.report, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        tmp.replace(self.out / "report.json")

    def step(self, name, argv, *, cwd=ROOT, env=None, expected=0, marker=None, timeout=None):
        print(f"[TESTE] {name}", flush=True)
        started = time.monotonic()
        log = self.out / (name + ".log")
        try:
            with log.open("wb") as stream:
                result = subprocess.run(
                    [str(x) for x in argv], cwd=cwd, env=env,
                    stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT,
                    timeout=timeout, check=False,
                )
            ok = result.returncode == expected
            if marker is not None:
                ok = ok and marker in log.read_bytes()
            row = {"name": name, "status": "PASS" if ok else "FAIL",
                   "exit_code": result.returncode}
        except (OSError, subprocess.TimeoutExpired) as exc:
            row = {"name": name, "status": "FAIL", "error_type": type(exc).__name__}
        row["seconds"] = round(time.monotonic() - started, 3)
        self.report["steps"].append(row)
        self.save()
        print(f"  {row['status']}", flush=True)
        return row["status"] == "PASS"

    def note(self, name, status):
        self.report["steps"].append({"name": name, "status": status})
        self.save()

    def parse(self, name, callback):
        try:
            result = callback()
        except (OSError, ValueError, KeyError, TypeError, IndexError, ZeroDivisionError):
            self.note(name, "FAIL")
            return None
        self.note(name, "PASS")
        return result


def read_count(path, pattern):
    try:
        return sum(1 for entry in path.iterdir() if re.fullmatch(pattern, entry.name))
    except OSError:
        return None


def go_env(network=False):
    env = dict(os.environ)
    env.update({"GOTOOLCHAIN": "local", "GOWORK": "off", "GOENV": "off", "GOFLAGS": ""})
    if not network:
        env["GOPROXY"] = "off"
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--binary", type=Path, help="installed experimental executable")
    target.add_argument("--build", action="store_true", help="build isolated binary; cached Go modules required")
    parser.add_argument("--mode", choices=PROFILES, default="quick")
    parser.add_argument("--legacy", type=Path, default=Path("/usr/local/bin/crias-tui"))
    parser.add_argument("--go-only", action="store_true", help="explicitly skip legacy comparison")
    parser.add_argument("--installed-release", help="operator declaration, not independently verified")
    parser.add_argument("--expected-binary-sha256", help="optional trusted expected digest")
    parser.add_argument("--source-audit", action="store_true", help="offline module/import/vet/race checks")
    parser.add_argument("--check-updates", action="store_true", help="allow network module-version query only")
    parser.add_argument("--output-parent", type=Path, default=Path.home())
    args = parser.parse_args()
    if sys.platform != "linux" or os.geteuid() == 0:
        parser.error("Linux and an unprivileged user are required")
    if sys.version_info < (3, 10):
        parser.error("Python 3.10+ required")
    if args.installed_release and not re.fullmatch(r"[A-Za-z0-9._+-]{1,80}", args.installed_release):
        parser.error("invalid release identifier")
    if args.expected_binary_sha256 and not re.fullmatch(r"[a-fA-F0-9]{64}", args.expected_binary_sha256):
        parser.error("expected SHA-256 must be 64 hexadecimal characters")
    os.umask(0o077)
    out = Path(tempfile.mkdtemp(prefix="crias-vm-", dir=args.output_parent.expanduser().resolve(strict=True)))
    suite = Suite(out, args)
    print(f"Evidências privadas: {out}", flush=True)
    count, idle, warmup = PROFILES[args.mode]
    suite.report["parameters"] = {"sessions_per_mode": count, "idle_seconds_per_mode": idle, "warmup_seconds": warmup}
    suite.report["host"] = {
        "kernel": platform.release(), "architecture": platform.machine(), "logical_cpus": os.cpu_count(),
        "hwmon_devices": read_count(Path("/sys/class/hwmon"), r"hwmon[0-9]+"),
        "thermal_zones": read_count(Path("/sys/class/thermal"), r"thermal_zone[0-9]+"),
        "cpufreq_policies": read_count(Path("/sys/devices/system/cpu/cpufreq"), r"policy[0-9]+"),
        "power_supplies": read_count(Path("/sys/class/power_supply"), r".+"),
        "powercap_domains": read_count(Path("/sys/class/powercap"), r".+:[0-9]+(?::[0-9]+)*"),
    }
    suite.report["declared_installed_release"] = args.installed_release
    suite.save()
    py = sys.executable
    env = go_env()
    go = shutil.which("go")
    module = ROOT / "crias-hub"
    locks = {}
    try:
        for name in ("go.mod", "go.sum"):
            locks[name] = digest(module / name)
        suite.report["source_locks_sha256"] = locks
        if not suite.step("checkout", ["git", "rev-parse", "HEAD"], timeout=10):
            raise ValueError("trusted Git checkout required")
        suite.report["checkout_sha"] = (out / "checkout.log").read_text().strip()
        if not suite.step("checkout-clean", ["git", "status", "--porcelain"], timeout=10):
            raise ValueError("cannot verify clean checkout")
        if (out / "checkout-clean.log").stat().st_size:
            suite.note("source-tree-clean", "FAIL")
            raise ValueError("checkout must be clean")
        if args.build or args.source_audit or args.check_updates:
            if not go or not suite.step("go-version", [go, "env", "GOVERSION"], env=env, timeout=10):
                raise ValueError("Go toolchain unavailable")
            if (out / "go-version.log").read_text().strip() != PIN:
                suite.note("pinned-toolchain", "FAIL")
                raise ValueError("pinned Go required")
        if args.build:
            binary = out / "crias-tui-next"
            build_env = {**env, "CGO_ENABLED": "0"}
            if not suite.step("build", [go, "build", "-mod=readonly", "-trimpath", "-o", binary,
                                       "./cmd/crias-tui-next"], cwd=module, env=build_env, timeout=300):
                raise ValueError("offline build failed")
        else:
            binary = executable(args.binary or shutil.which("crias-tui-next") or Path.home() / ".local/bin/crias-tui-next")
        binary_hash = digest(binary)
        suite.report["binary_sha256"] = binary_hash
        if args.expected_binary_sha256 and binary_hash != args.expected_binary_sha256.lower():
            suite.note("binary-identity", "FAIL")
            raise ValueError("binary digest mismatch")
        suite.report["binary_identity"] = "hash-matched" if args.expected_binary_sha256 else "recorded-not-externally-verified"
        if go:
            if suite.step("binary-build-info", [go, "version", "-m", binary], env=env, timeout=10):
                info = (out / "binary-build-info.log").read_text()
                revisions = re.findall(r"^\s*build\s+vcs\.revision=([0-9a-f]{40})$", info, re.M)
                suite.report["binary_source_revision"] = revisions[0] if len(revisions) == 1 else None
                suite.report["binary_matches_checkout"] = suite.report["binary_source_revision"] == suite.report["checkout_sha"]
        else:
            suite.report["binary_matches_checkout"] = None
        if args.source_audit:
            gofmt = shutil.which("gofmt")
            if not gofmt:
                suite.note("gofmt", "FAIL")
            elif suite.step("gofmt", [gofmt, "-l", "."], cwd=module, timeout=30):
                suite.note("format-clean", "PASS" if not (out / "gofmt.log").stat().st_size else "FAIL")
            for name, cmd in (
                ("module-tidy", ["mod", "tidy", "-diff"]),
                ("module-verify", ["mod", "verify"]),
                ("imports", ["list", "-mod=readonly", "-deps", "./..."]),
                ("vet", ["vet", "-mod=readonly", "./..."]),
                ("race", ["test", "-mod=readonly", "-race", "-timeout", "120s", "./..."]),
            ):
                suite.step(name, [go, *cmd], cwd=module, env=env, timeout=300)
            suite.step("docs-links", [py, ROOT / "tests/docs-links-test.py"], timeout=60)
        if args.check_updates:
            suite.step("module-updates", [go, "list", "-m", "-u", "-mod=readonly", "all"],
                       cwd=module, env=go_env(network=True), timeout=120)
        suite.step("help", [binary, "--help"], marker=b"--telemetry", timeout=10)
        suite.step("version", [binary, "--version"], marker=b"C03", timeout=10)
        suite.step("reject-no-tty", [binary], expected=2, marker=b"Terminal interativo", timeout=10)
        suite.step("evidence-contract", [py, ROOT / "tests/hub-c03-evidence-test.py"],
                   marker=b"OK: C03 raw evidence", timeout=20)
        if not args.go_only:
            legacy = args.legacy.expanduser().resolve(strict=True)
            if not legacy.is_file():
                raise ValueError("trusted installed legacy script required")
            suite.report["legacy_sha256"] = digest(legacy)
            suite.step("gum-negative", [py, ROOT / "tests/hub-gum-negative-test.py"],
                       marker=b"OK: C00 Gum benchmark negative contracts (9 cases)", timeout=60)
            if suite.step("legacy-numeric", [py, ROOT / "tools/hub-baseline.py", "--hub", legacy,
                                            "--mode", "host", "--samples", count]):
                suite.parse("legacy-numeric-json", lambda: report_from_log(out / "legacy-numeric.log"))
            if suite.step("legacy-gum", [py, ROOT / "tools/hub-gum-baseline.py", "--hub", legacy,
                                        "--mode", "host", "--samples", count, "--idle-seconds", idle]):
                suite.parse("legacy-gum-json", lambda: report_from_log(out / "legacy-gum.log"))
            if digest(legacy) != suite.report["legacy_sha256"]:
                suite.note("legacy-unchanged", "FAIL")
        else:
            suite.note("legacy-comparison", "SKIP")
        # PTY harness owns child cleanup and per-frame deadlines. Do not kill
        # the outer Python process with an arbitrary aggregate timeout.
        harness = ROOT / "tests/hub-c01-pty-test.py"
        if suite.step("go-lifecycle", [py, harness, binary, "--samples", count, "--idle-seconds", 5]):
            suite.parse("go-lifecycle-json", lambda: report_from_log(out / "go-lifecycle.log", "HUB_C01_PTY_JSON="))
        if suite.step("go-telemetry", [py, harness, binary, "--compare-telemetry", "--samples", count,
                                       "--idle-seconds", idle, "--warmup-seconds", warmup]):
            data = suite.parse("go-telemetry-json", lambda: report_from_log(out / "go-telemetry.log", "HUB_C03_PTY_JSON="))
            if data is not None:
                suite.report["telemetry"] = suite.parse("go-telemetry-integrity", lambda: telemetry_summary(data, binary_hash, count, idle))
        suite.note("binary-unchanged", "PASS" if digest(binary) == binary_hash else "FAIL")
        suite.note("module-locks-unchanged", "PASS" if all(digest(module / n) == h for n, h in locks.items()) else "FAIL")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"Validação interrompida: {exc}", file=sys.stderr)
        suite.note("preflight-or-execution", "FAIL")
    except KeyboardInterrupt:
        suite.note("interrupted", "FAIL")
    finally:
        failed = any(step["status"] == "FAIL" for step in suite.report["steps"])
        suite.report["automatic_status"] = "FAIL" if failed else "PASS"
        suite.save()
    print(f"Resultado automatizado: {suite.report['automatic_status']}; M2 continua aberto.")
    print(f"Relatório: {out / 'report.json'}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
