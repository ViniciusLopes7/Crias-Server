#!/usr/bin/env python3
"""Contract tests for VM report validation; no host changes."""
import copy
import runpy
from pathlib import Path

ns = runpy.run_path(str(Path(__file__).resolve().parents[1] / "tools/hub-vm-validation.py"))
summarize = ns["telemetry_summary"]
idle = {
    "seconds": 60.1, "cpu_sample_seconds": 60, "memory_sample_count": 2,
    "raw_samples": [[0, 0, 0, 8000, 8100, 7900], [60000000000, 25, 5, 8000, 8100, 7900]],
    "cpu_main_plus_waited_percent_one_core": 0.5,
    "rss_kib": ns["metric_summary"]([8000, 8000]),
    "rollup_rss_kib": ns["metric_summary"]([8100, 8100]),
    "pss_kib": ns["metric_summary"]([7900, 7900]),
    "rollup_rss_missing_samples": 0, "pss_missing_samples": 0, "rss_delta_kib": 0,
}
mode = {"idle": idle, "samples": [{"startup_ms": 20, "navigation_ms": [16, 17]}],
        "startup_ms": ns["metric_summary"]([20]), "navigation_ms": ns["metric_summary"]([16, 17])}
report = {"schema": 2, "mode": "hub-telemetry-comparison", "binary_sha256": "a" * 64,
          "binary_bytes": 6000000, "clock_ticks_per_second": 100,
          "modes": {name: copy.deepcopy(mode) for name in ns["MODES"]}}
assert summarize(report, "a" * 64, 1, 60)["balanced"]["cpu_reference_met"]
for field, value in (("schema", 1), ("binary_sha256", "b" * 64), ("clock_ticks_per_second", 0)):
    bad = copy.deepcopy(report)
    bad[field] = value
    try:
        summarize(bad, "a" * 64, 1, 60)
    except ValueError:
        pass
    else:
        raise AssertionError(field)
bad = copy.deepcopy(report)
bad["modes"]["balanced"]["idle"]["raw_samples"][1][1] = 50
try:
    summarize(bad, "a" * 64, 1, 60)
except ValueError:
    pass
else:
    raise AssertionError("unverified CPU summary accepted")
for column in (3, 4, 5):
    bad = copy.deepcopy(report)
    bad["modes"]["balanced"]["idle"]["raw_samples"][1][column] = 7000
    try:
        summarize(bad, "a" * 64, 1, 60)
    except ValueError:
        pass
    else:
        raise AssertionError("unverified memory summary accepted")
print("OK: VM validation report contracts")
