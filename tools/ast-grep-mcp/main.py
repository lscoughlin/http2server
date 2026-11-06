"""Project MCP server for ast-grep structural search over Pascal sources.

Exposes four tools: find_code, find_code_by_rule, test_match_code_rule and
dump_syntax_tree. Each tool shells out to the ast-grep CLI with the project
sgconfig.yml and --custom-languages allow.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("ast-grep")

_ARGS: argparse.Namespace | None = None


def _root() -> Path:
    # tools/ast-grep-mcp/main.py -> repository root.
    return Path(__file__).resolve().parent.parent.parent


def _run_ast_grep(args: list[str]) -> str:
    assert _ARGS is not None
    binary = shutil.which("ast-grep")
    if binary is None:
        return "error: the ast-grep binary is not on PATH (install it with `brew install ast-grep`)"
    config = Path(_ARGS.config)
    if not config.is_absolute():
        config = _root() / config
    proc = subprocess.run(
        [binary, "-c", str(config), "--custom-languages", "allow", *args],
        cwd=str(_root()),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
    )
    out = proc.stdout.strip()
    err = proc.stderr.strip()
    if out:
        return out if not err else out + "\n\nstderr:\n" + err
    if proc.returncode == 0:
        return "(no matches)"
    return "error:\n" + (err or out or f"exit {proc.returncode}")


@mcp.tool()
def find_code(pattern: str, language: str = "pascal", paths: list[str] | None = None) -> str:
    """Match an AST pattern against the sources.

    pattern: ast-grep pattern text. Pascal metavariables use the _NAME form
    (expandoChar _), e.g. a full type block, not a bare call fragment.
    language: ast-grep language name; this repo only registers pascal.
    paths: repository-relative search roots; defaults to the whole tree.
    """
    return _run_ast_grep(
        ["run", "--lang", language, "-p", pattern, "--", *(paths or ["."])]
    )


@mcp.tool()
def find_code_by_rule(rule: str, paths: list[str] | None = None) -> str:
    """Scan the sources with a YAML rule (kind/regex/has constraints).

    rule: one ast-grep rule document, including id and language: pascal.
    paths: repository-relative search roots; defaults to the whole tree.
    """
    return _run_ast_grep(["scan", "--inline-rules", rule, "--", *(paths or ["."])])


@mcp.tool()
def test_match_code_rule(rule: str, snippet: str) -> str:
    """Check whether a YAML rule matches a Pascal snippet.

    rule: one ast-grep rule document with language: pascal.
    snippet: Pascal source text to match against.
    """
    with tempfile.NamedTemporaryFile(
        "w", suffix=".pas", prefix="snippet-", delete=False
    ) as handle:
        handle.write(snippet)
        probe = handle.name
    try:
        return _run_ast_grep(["scan", "--inline-rules", rule, "--", probe])
    finally:
        Path(probe).unlink(missing_ok=True)


@mcp.tool()
def dump_syntax_tree(pattern: str, language: str = "pascal") -> str:
    """Print the tree-sitter AST of a pattern (shows real node kind names)."""
    return _run_ast_grep(
        ["run", "--lang", language, "--debug-query=ast", "-p", pattern, "--", "/dev/null"]
    )


def main() -> None:
    global _ARGS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        default="sgconfig.yml",
        help="ast-grep project config, relative to the repository root",
    )
    _ARGS = parser.parse_args()
    mcp.run()


if __name__ == "__main__":
    main()
