#!/usr/bin/env python3
"""Check local Markdown links; external links remain outside this test."""
from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"\[[^\]\n]+\]\(([^)\n]+)\)")
SKIP = ("http:", "https:", "mailto:", "data:", "plugin:", "sandbox:")
errors = []
files = sorted(path for path in ROOT.rglob("*.md") if ".git" not in path.parts)
for file in files:
    text = file.read_text(encoding="utf-8")
    clean = []
    fenced = False
    for line in text.splitlines():
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if not fenced:
            clean.append(line)
    for match in LINK.finditer("\n".join(clean)):
        raw = match.group(1).strip()
        target = raw.split(" \"", 1)[0].strip("<>")
        if not target or target.startswith(SKIP) or target.startswith("#"):
            continue
        path_part = unquote(urlsplit(target).path)
        if not path_part:
            continue
        candidate = (file.parent / path_part).resolve()
        try:
            candidate.relative_to(ROOT)
        except ValueError:
            errors.append(f"{file.relative_to(ROOT)}: link escapes repo: {raw}")
            continue
        if not candidate.exists():
            errors.append(f"{file.relative_to(ROOT)}: missing {raw}")

for error in errors:
    print("BROKEN:", error)
print(f"Checked {len(files)} Markdown files: {len(errors)} broken local links")
raise SystemExit(1 if errors else 0)
