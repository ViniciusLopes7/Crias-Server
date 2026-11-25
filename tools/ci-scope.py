#!/usr/bin/env python3
"""Determine Discord component CI scope from the complete Git diff.

Unknown history fails open (run both), never silently skips validation.
Release and manual runs always validate both components.
"""
import json
import os
import subprocess
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.PIPE)


def classify(paths):
    agent = bot = False
    for path in paths:
        if (path.startswith(".github/workflows/")
                or path in {"tools/ci-scope.py", "tests/ci-scope-test.py"}
                or path.startswith(".github/actions/")):
            return True, True
        if path.startswith("discord-agent/"):
            agent = True
        if path.startswith(("discord-bot/", "discord-agent/proto/")) or path == ".dockerignore":
            bot = True
    return agent, bot


def scope(event, ref, payload):
    if event == "workflow_dispatch" or ref.startswith("refs/tags/"):
        return True, True, "manual/tag full validation"
    if event == "push" and ref == "refs/heads/main":
        message = (payload.get("head_commit") or {}).get("message", "")
        if "[release]" in message:
            return True, True, "release full validation"
    try:
        if event == "pull_request":
            pr = payload["pull_request"]
            end = pr["head"]["sha"]
            base = pr["base"]["sha"]
            if not all(valid_sha(x) for x in (end, base)):
                raise ValueError("invalid PR SHA")
            start = git("merge-base", base, end).decode().strip()
        elif event == "push":
            start, end = payload["before"], payload["after"]
        else:
            return True, True, "unknown event"
        if not all(valid_sha(x) for x in (start, end)):
            raise ValueError("missing or invalid diff endpoint")
        # --no-renames ensures both sides of a cross-component move count.
        paths = git("diff", "--name-only", "-z", "--no-renames",
                    start, end, "--").decode("utf-8", "surrogateescape").split("\0")
        agent, bot = classify(paths)
        return agent, bot, "complete Git diff"
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        return True, True, "diff unavailable: conservative full validation"


def valid_sha(value):
    return (isinstance(value, str) and len(value) == 40
            and all(c in "0123456789abcdef" for c in value)
            and value != "0" * 40)


def main():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        payload = json.load(stream)
    agent, bot, reason = scope(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], payload)
    print(f"CI scope: agent={agent}, bot={bot}; {reason}")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
        stream.write(f"agent={str(agent).lower()}\nbot={str(bot).lower()}\n")


if __name__ == "__main__":
    main()
