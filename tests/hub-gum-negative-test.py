#!/usr/bin/env python3
"""Negative contracts for the legacy Gum benchmark; disposable fixtures only."""
import contextlib
import io
import os
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/hub-gum-baseline.py"


def missing_gum():
    # Simulate absence even when the CI/host has Gum. Never modify PATH
    # on the host or uninstall the actual executable.
    ns = runpy.run_path(str(TOOL))
    stdout, stderr = io.StringIO(), io.StringIO()
    with (
        patch.object(sys, "argv", [str(TOOL), "--samples", "1"]),
        patch("shutil.which", return_value=None),
        contextlib.redirect_stdout(stdout),
        contextlib.redirect_stderr(stderr),
    ):
        try:
            ns["main"]()
        except SystemExit as exc:
            assert exc.code == 2, exc.code
        else:
            raise AssertionError("missing Gum accepted")
    assert not stdout.getvalue()
    assert "healthy Gum must already be installed" in stderr.getvalue()
    print("PASS: missing Gum fails without auto-install")


def run_case(directory, name, body, expected, gum_version="echo fixture-gum"):
    # This is a CLI negative test, not a measurement of real Gum.
    gum = directory / "gum"
    gum.write_text("#!/bin/bash\n" + gum_version + "\n")
    gum.chmod(0o700)
    hub = directory / "hub.sh"
    hub.write_text("main() {\n" + body + "\n}\n")
    result = subprocess.run(
        [sys.executable, str(TOOL), "--hub", str(hub), "--gum-dir", str(directory),
         "--samples", "1", "--timeout", "1"],
        capture_output=True, text=True, timeout=15,
    )
    assert result.returncode == 1, (name, result.returncode, result.stderr)
    assert not result.stdout, (name, "partial benchmark emitted")
    assert expected in result.stderr, (name, result.stderr)
    print(f"PASS: {name}; no benchmark JSON")


def main():
    if os.geteuid() == 0:
        raise RuntimeError("run negative benchmark tests without root")
    missing_gum()
    with tempfile.TemporaryDirectory(prefix="crias-gum-negative-") as tmp:
        directory = Path(tmp)
        run_case(directory, "unhealthy Gum", "exit 0", "returned non-zero exit status", "exit 7")
        run_case(directory, "empty Gum version", "exit 0", "Gum version not identifiable", ":")
        run_case(directory, "premature PTY close", "exit 0", "PTY closed")
        run_case(directory, "numeric fallback", "printf 'modo numerado\\n'; sleep 5",
                 "Gum route fell back to numeric menu")
        run_case(directory, "unexpected administrative operation", "sudo echo forbidden",
                 "unexpected administrative operation")
        run_case(directory, "unexpected frame timeout", "printf 'Menu desconhecido\\n'; sleep 5",
                 "expected real Gum frame not observed")
        run_case(directory, "silent timeout", "sleep 5", "expected real Gum frame not observed")
        run_case(directory, "bounded output", "head -c 300000 /dev/zero; sleep 5",
                 "unexpected frame output exceeds limit")
    print("OK: C00 Gum benchmark negative contracts (9 cases)")


if __name__ == "__main__":
    main()
