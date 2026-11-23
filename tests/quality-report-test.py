#!/usr/bin/env python3
"""Quality report is measurable and does not accidentally include ignored files."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("quality_report", ROOT / "tools/quality-report.py")
assert SPEC is not None and SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class QualityReportTests(unittest.TestCase):
    def test_function_spans_are_candidates_not_exact_lines(self) -> None:
        source = "first() {\n  echo a\n}\nsecond() {\n  echo b\n}\n"
        self.assertEqual(module.shell_function_spans(source), [("first", 1, 3), ("second", 4, 3)])

    def test_snapshot_excludes_untracked_and_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "tools").mkdir()
            (root / "tests").mkdir()
            (root / "docs").mkdir()
            (root / "app.sh").write_text("main() {\n  true\n}\n", encoding="utf-8")
            (root / "tests" / "case.sh").write_text("exit 0\n", encoding="utf-8")
            (root / "docs" / "guide.md").write_text("# Guia\n", encoding="utf-8")
            (root / ".gitignore").write_text("untracked.sh\n", encoding="utf-8")
            (root / "untracked.sh").write_text("nope() {}\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "."], check=True)
            # A new repository has no HEAD until its first commit.
            subprocess.run(["git", "-C", str(root), "-c", "user.name=CI",
                            "-c", "user.email=ci@example.invalid",
                            "commit", "-qm", "fixture"], check=True)
            report = module.report(root)
            self.assertEqual(report["shell_files"], 2)
            self.assertEqual(report["test_directory_files"], 1)
            self.assertEqual(report["docs_directory_markdown"], 1)
            self.assertEqual(report["production_code_lines"], 3)
            self.assertEqual(report["tracked_files"], 4)
            baseline = subprocess.check_output(
                ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
            ).strip()
            (root / "app.sh").write_text("main() {\n  true\n  echo changed\n}\n", encoding="utf-8")
            newer = module.report(root)
            old = module.report(root, ref=baseline)
            self.assertEqual(old["production_code_lines"], 3)
            self.assertEqual(newer["production_code_lines"], 4)
            self.assertEqual(old["git_sha"], baseline)

    def test_cli_json_and_markdown(self) -> None:
        result = subprocess.check_output(
            ["python3", str(ROOT / "tools/quality-report.py"), "--format", "json"],
            cwd=ROOT, text=True,
        )
        data = json.loads(result)
        self.assertEqual(data["schema_version"], 1)
        self.assertGreater(data["tracked_files"], 100)
        self.assertGreater(data["shell_files"], 50)
        text = subprocess.check_output(
            ["python3", str(ROOT / "tools/quality-report.py"), "--format", "markdown"],
            cwd=ROOT, text=True,
        )
        self.assertIn("Inventário de qualidade", text)
        compare = subprocess.check_output(
            ["python3", str(ROOT / "tools/quality-report.py"), "--format", "json",
             "--compare-ref", "HEAD"], cwd=ROOT, text=True,
        )
        delta = json.loads(compare)["delta_vs_baseline"]
        self.assertTrue(all(value == 0 for value in delta.values()))

    def test_policy_links_exist(self) -> None:
        for path in ("CONTRIBUTING.md", "docs/engineering-quality.md",
                     "docs/architecture.md", "docs/quality-baseline.md",
                     "docs/decisions/0001-quality-first.md",
                     ".github/pull_request_template.md"):
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())


if __name__ == "__main__":
    unittest.main()
