#!/usr/bin/env python3
"""Verify the C03 benchmark schema without a live Hub or extra runner."""
import runpy
from pathlib import Path

ns = runpy.run_path(str(Path(__file__).with_name("hub-c01-pty-test.py")))
parse = ns["parse_rollup"]
report = ns["idle_report"]
assert parse("Rss: 200 kB\nPss: 150 kB\n") == (200, 150)
assert parse("Rss: 200 kB\nRss: 201 kB\nPss: -1 kB\n") == (None, None)
assert parse("Pss: 10 MB\n") == (None, None)
samples = [
    {"stamp_ns": 1000000000, "main_ticks": 10, "waited_child_ticks": 2,
     "rss_kib": 100, "rollup_rss_kib": 120, "pss_kib": 110},
    {"stamp_ns": 2000000000, "main_ticks": 11, "waited_child_ticks": 2,
     "rss_kib": 104, "rollup_rss_kib": None, "pss_kib": None},
    {"stamp_ns": 3000000000, "main_ticks": 12, "waited_child_ticks": 3,
     "rss_kib": 108, "rollup_rss_kib": 128, "pss_kib": 114},
]
out = report(samples, 2.1, 21, 100)
assert out["cpu_sample_seconds"] == 2
assert out["cpu_main_percent_one_core"] == 1
assert out["cpu_waited_children_percent_one_core"] == 0.5
assert out["cpu_main_plus_waited_percent_one_core"] == 1.5
assert out["pty_bytes_per_second"] == 10
assert out["rss_kib"]["median"] == 104
assert out["rollup_rss_kib"]["median"] == 124
assert out["pss_kib"]["median"] == 112
assert out["pss_missing_samples"] == out["rollup_rss_missing_samples"] == 1
assert out["raw_samples"][-1] == [2000000000, 2, 1, 108, 128, 114]
for bad in ([samples[0], samples[0]], [samples[0], {**samples[-1], "main_ticks": 9}]):
    try:
        report(bad, 2, 0, 100)
    except RuntimeError:
        pass
    else:
        raise AssertionError("invalid counters accepted")
print("OK: C03 raw evidence, rollup, CPU duration and counter validation")
