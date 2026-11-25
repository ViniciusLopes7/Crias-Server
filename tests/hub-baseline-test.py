#!/usr/bin/env python3
"""Smoke test the numeric benchmark using actual legacy Hub with fixtures."""
import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tool = root / "tools/hub-baseline.py"
for stack in ("minecraft", "terraria"):
    result = subprocess.run(
        [sys.executable, str(tool), "--stack", stack, "--samples", "2"],
        check=True, capture_output=True, text=True, timeout=45,
    )
    report = json.loads(result.stdout)
    assert report["mode"] == "fixture"
    assert report["stack"] == stack
    assert report["startup_ms"]["count"] == 2
    assert report["navigation_ms"]["count"] == 4
    assert len(report["hub_sha256"]) == 64
    assert len(report["samples"]) == 2
    for row in report["samples"]:
        assert row["startup_ms"] >= 0
        assert len(row["navigation_ms"]) == 2
        assert all(value >= 0 for value in row["navigation_ms"])
bad = subprocess.run(
    [sys.executable, str(tool), "--samples", "0"],
    capture_output=True, text=True, timeout=10,
)
assert bad.returncode != 0 and not bad.stdout
print("OK: benchmark PTY fixture, both stacks, JSON and invalid argument")
