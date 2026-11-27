#!/usr/bin/env python3
"""Test CI scope classification and actual git diff semantics."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ci_scope", ROOT / "tools/ci-scope.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class ScopeTest(unittest.TestCase):
    def test_paths(self):
        cases = [
            (["crias-hub/main.go", "docs/a.md", "minecraft/install.sh"], (False, False)),
            (["discord-agent/internal/server.go"], (True, False)),
            (["discord-bot/src/bot.py"], (False, True)),
            (["discord-agent/proto/crias.proto"], (True, True)),
            ([".dockerignore"], (False, True)),
            ([".github/workflows/ci.yml"], (True, True)),
            ([".github/actions/example/action.yml"], (True, True)),
            (["tools/ci-scope.py"], (True, True)),
            (["tests/ci-scope-test.py"], (True, True)),
            (["discord-agent/x", "discord-bot/y"], (True, True)),
            ([], (False, False)),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertEqual(ci.classify(paths), expected)

    def test_full_and_unknown(self):
        for event, ref, payload in [
            ("workflow_dispatch", "refs/heads/main", {}),
            ("push", "refs/tags/v1.0.0", {}),
            ("push", "refs/heads/main", {"head_commit": {"message": "ship [release]"}}),
            ("push", "refs/heads/main", {"before": "0"*40, "after": "a"*40}),
            ("pull_request", "refs/pull/1/merge", {}),
            ("other", "refs/heads/main", {}),
        ]:
            with self.subTest(event=event, ref=ref):
                self.assertEqual(ci.scope(event, ref, payload)[:2], (True, True))

    def test_real_history(self):
        old = Path.cwd()
        with tempfile.TemporaryDirectory() as tmp:
            try:
                os.chdir(tmp)
                def git(*args):
                    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE).decode().strip()
                git("init", "-b", "main")
                git("config", "user.email", "fixture@example.invalid")
                git("config", "user.name", "CI fixture")
                def commit(path, content):
                    p = Path(path)
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text(content)
                    git("add", "-A")
                    git("commit", "-m", path)
                    return git("rev-parse", "HEAD")
                base = commit("README.md", "base")
                git("checkout", "-b", "feature")
                agent = commit("discord-agent/a.go", "agent")
                hub = commit("crias-hub/a.go", "hub")
                self.assertEqual(ci.scope("push", "refs/heads/main", {"before": base, "after": hub})[:2], (True, False))
                self.assertEqual(ci.scope("push", "refs/heads/main", {"before": agent, "after": hub})[:2], (False, False))
                git("checkout", "main")
                main = commit("discord-bot/b.py", "base-only change")
                event = {"pull_request": {"base": {"sha": main}, "head": {"sha": hub}}}
                self.assertEqual(ci.scope("pull_request", "refs/pull/1/merge", event)[:2], (True, False))
                git("checkout", "feature")
                Path("discord-agent/a.go").unlink()
                moved = commit("discord-bot/a.py", "agent")
                self.assertEqual(ci.scope("push", "refs/heads/main", {"before": hub, "after": moved})[:2], (True, True))
                self.assertEqual(ci.scope("push", "refs/heads/main", {"before": "f"*40, "after": moved})[:2], (True, True))
            finally:
                os.chdir(old)


if __name__ == "__main__":
    unittest.main()
