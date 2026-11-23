#!/usr/bin/env python3
"""Deterministic, dependency-free quality inventory; informational, not a LoC gate."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL_FN = re.compile(r"^(?:function\s+)?([a-zA-Z_][a-zA-Z_0-9]*)\s*\(\s*\)\s*\{")


def git_output(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)


def tracked_files(root: Path) -> list[Path]:
    """Only tracked files count; never include local caches, secrets or .git."""
    names = git_output(root, "ls-files", "-z").decode("utf-8").split("\0")
    return [root / p for p in sorted(n for n in names if n) if (root / p).is_file()]


def shell_function_spans(source: str) -> list[tuple[str, int, int]]:
    """Approximate upper-bound spans until next top-level function, NOT cyclomatic complexity."""
    lines = source.splitlines()
    starts = [(m.group(1), i + 1) for i, line in enumerate(lines) if (m := SHELL_FN.match(line))]
    return [
        (name, start, (starts[i + 1][1] - start if i + 1 < len(starts) else len(lines) - start + 1))
        for i, (name, start) in enumerate(starts)
    ]


def report(root: Path = ROOT) -> dict:
    files = tracked_files(root)
    extension_counts: Counter[str] = Counter()
    test_files = docs_files = production_lines = 0
    hotspots: list[dict] = []
    duplicate_names: dict[str, list[str]] = defaultdict(list)
    largest: list[dict] = []
    for path in files:
        rel = path.relative_to(root).as_posix()
        if rel.startswith("tests/"):
            test_files += 1
        if rel.startswith("docs/") and path.suffix == ".md":
            docs_files += 1
        if path.suffix not in (".sh", ".go", ".py", ".md"):
            continue
        extension_counts[path.suffix] += 1
        if not path.is_file():
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeError:
            continue
        lines = len(source.splitlines())
        if path.suffix in (".sh", ".go", ".py") and not rel.startswith("tests/"):
            production_lines += lines
            largest.append({"path": rel, "lines": lines})
        if path.suffix == ".sh" and not rel.startswith("tests/"):
            for name, line, span in shell_function_spans(source):
                duplicate_names[name].append(rel)
                if span >= 80:
                    hotspots.append({"path": rel, "function": name, "start_line": line, "approx_span": span})
    repeated = [{"function": name, "files": sorted(set(paths))}
                for name, paths in sorted(duplicate_names.items())
                if len(set(paths)) > 1]
    return {
        "schema_version": 1,
        "git_sha": git_output(root, "rev-parse", "HEAD").decode().strip(),
        "tracked_files": len(files),
        "shell_files": extension_counts[".sh"],
        "go_files": extension_counts[".go"],
        "python_files": extension_counts[".py"],
        "markdown_files": extension_counts[".md"],
        "test_directory_files": test_files,
        "docs_directory_markdown": docs_files,
        "production_code_lines": production_lines,
        "largest_production_files": sorted(largest, key=lambda e: (-e["lines"], e["path"]))[:15],
        "shell_function_candidates": sorted(hotspots, key=lambda e: (-e["approx_span"], e["path"], e["start_line"]))[:25],
        "repeated_shell_names": repeated,
    }


def as_markdown(data: dict, comparison: dict | None = None) -> str:
    keys = (
        ("Arquivos versionados", "tracked_files"),
        ("Arquivos Shell", "shell_files"),
        ("Arquivos Go", "go_files"),
        ("Arquivos Python", "python_files"),
        ("Markdown", "markdown_files"),
        ("Arquivos em tests/", "test_directory_files"),
        ("Markdown em docs/", "docs_directory_markdown"),
        ("Linhas de código de produção (aprox.)", "production_code_lines"),
    )
    out = [f"# Inventário de qualidade — {data['git_sha'][:12]}", "",
           "Este relatório é observacional; nenhum número implica automaticamente qualidade ou problema.", "",
           "| Medida | Atual | Diferença para referência |", "|---|---:|---:|"]
    for title, key in keys:
        delta = ("não comparado" if comparison is None
                 else f"{data[key] - comparison[key]:+d}")
        out.append(f"| {title} | {data[key]} | {delta} |")
    out.extend(["", "## Candidatos Shell à revisão (span aproximado)", "",
                "| Caminho | Função | Span até próxima função |", "|---|---|---:|"])
    for item in data["shell_function_candidates"]:
        out.append(f"| {item['path']}:{item['start_line']} | {item['function']} | {item['approx_span']} |")
    out.extend(["", "Não usar a métrica como contagem exata de corpo, cobertura ou complexidade ciclomática.",
                "Confirmar consumidores antes de remover funções com nomes repetidos."])
    return "\n".join(out) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", choices=("json", "markdown"), default="markdown")
    parser.add_argument("--compare", type=Path, help="JSON de referência gerado por esta ferramenta")
    args = parser.parse_args()
    current = report()
    previous = None
    if args.compare is not None:
        previous = json.loads(args.compare.read_text(encoding="utf-8"))
        if previous.get("schema_version") != current["schema_version"]:
            parser.error("schema_version da referência incompatível")
    if args.format == "json":
        if previous:
            current["delta_vs_baseline"] = {
                key: current[key] - previous[key]
                for key in ("tracked_files", "shell_files", "go_files", "python_files",
                            "markdown_files", "test_directory_files",
                            "docs_directory_markdown", "production_code_lines")
            }
        print(json.dumps(current, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(as_markdown(current, previous), end="")


if __name__ == "__main__":
    main()
