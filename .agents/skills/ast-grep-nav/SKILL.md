---
name: ast-grep-nav
description: Structural (AST-based) code search and rewrite for the Pascal sources using ast-grep with a vendored tree-sitter-pascal grammar. Use when a search is about code *shape* (every class that implements an interface, every call of a given method) rather than an exact symbol name or a plain text string.
---

# ast-grep Structural Search

This project searches its Pascal sources (`src/`, `test/`, `examples/`,
`tools/`) with the `ast-grep` CLI (installed via `brew install ast-grep`),
plus a project MCP server (`tools/ast-grep-mcp`, server name `ast-grep` in
`.mcp.json`). The server exposes four tools: `find_code`,
`find_code_by_rule`, `test_match_code_rule`, `dump_syntax_tree`. If MCP tools
are not available in the current context, the same search is reachable
through the CLI directly. Every example below shows the CLI form.

Pascal is not built into ast-grep. It runs here as a *custom* language,
backed by a vendored `tree-sitter-pascal` grammar
(`third_party/tree-sitter-pascal`, built by
`task vendor:tree-sitter-pascal`) registered in `sgconfig.yml` at the repo
root. There is no TypeScript in this repo, so none of ast-grep's built-in
languages apply here.

## When to use this

Three tools cover overlapping ground; pick by what is known:

- **`ctags-nav`** — the exact name of a class/interface/record/method/unit
  and its definition is needed. Fastest and most precise; use it first for
  name lookups.
- **`ast-grep` (this skill)** — the *shape* of the code is known, not a
  specific name: "every class that implements `IHttp2Server`", "every place
  `.Free` is called". Structural match ignores whitespace and format
  differences and does not match inside a comment or string literal.
- **`rg`** — plain text: string literals, comments, log messages, or a scan
  for a substring when the shape is not certain.

## Setup (read before the first search)

1. Build the parser once: `task vendor:tree-sitter-pascal`. It clones the
   pinned grammar to `third_party/` (local only, never committed) and
   compiles `libtree-sitter-pascal.dylib` next to it.
2. Every CLI invocation needs `--custom-languages allow`. Since ast-grep
   0.50 the CLI skips native custom-language libraries unless this opt-in
   is present. Without it the `pascal` language is silently ignored.
3. Run from the repo root. ast-grep finds `sgconfig.yml` by itself there.
   From outside the tree, add `-c sgconfig.yml` **after** the `run`
   subcommand (`ast-grep run -c sgconfig.yml ...`). Flags before `run`
   confuse argument parsing, so keep every flag after `run`.

## Gotchas (read before writing a pattern)

tree-sitter-pascal is a custom, non-built-in language for ast-grep, with
sharp edges that do not show up with built-in languages:

1. **Metavariables use `_NAME`, not `$NAME`.** Pascal hex literals (`$FF`)
   collide with ast-grep's default `$METAVAR` sigil, so `sgconfig.yml`
   sets `expandoChar: _` for `pascal`. Every metavariable in a Pascal
   pattern is `_UpperCaseName`, e.g. `_OBJ`, `_NAME`, `_IFACE`.
2. **Bare statement/expression pattern strings usually fail to parse on
   their own.** Unlike mainstream grammars, tree-sitter-pascal gives
   ast-grep no way to wrap a lone fragment like `_OBJ.Free()` in valid
   context. The result is `Error: Cannot parse query as a valid pattern`
   or `Warning: Pattern contains an ERROR node`, even for patterns that
   are valid Pascal in context. Two ways around it:
   - For **declarations** (types, classes), write the full enclosing
     shape in the pattern text — the `type` keyword through `end;` —
     rather than just the header. This still misses documented classes
     (a `///` comment between `type` and the class stops the match), so
     the worked example below uses a rule instead.
   - For **statements/expressions** (a specific call shape, wherever it
     occurs), match by **AST kind** instead of pattern text — `--kind
     <KIND>` on the CLI, or `find_code_by_rule` with a YAML `rule:
     {kind: ..., ...}` over MCP. This matches every node of that kind
     and does not need the fragment itself to be parseable alone.
3. **A call without parentheses is `exprDot`, not `exprCall`.** In this
   grammar `FAsync.Free;` parses as an `exprDot` node (`FAsync.Free`).
   `exprCall` only matches calls with an argument list, such as
   `High(LongInt)` or `SetValue(AName, AValue)`. A rule for `.Free`
   therefore constrains `kind: exprDot`, not `kind: exprCall`.
4. **Two constructs in this tree parse with local ERROR nodes.** A bare
   re-raise (`raise;` with no operand) and an inline conditional such as
   `{$IFDEF WINDOWS}stdcall{$ELSE}cdecl{$ENDIF}` inside a declaration
   produce ERROR nodes. The rest of the file still parses, and kind
   matches still work around them. Prefer kind- or rule-based matches
   near these lines.

Use `dump_syntax_tree` (MCP) or `ast-grep run --lang pascal
--debug-query=ast -p '<snippet>' /dev/null` (CLI, with
`--custom-languages allow`) to see the actual node kinds
tree-sitter-pascal uses. They are distinctive — `declClass`, `declType`,
`exprCall`, `exprDot`, `typeref`, `kClass` — not the names from a
mainstream grammar.

## Worked example: find class declarations by interface

Find every class that implements a given interface (the shape
`src/Http2Server.Server.pas` uses for `THttp2Server =
class(TInterfacedObject, IHttp2Server)`). Match the `declClass` node with
a YAML rule and anchor the expression on the class header:

```bash
ast-grep scan --custom-languages allow -c sgconfig.yml --inline-rules 'id: class-by-interface
language: pascal
severity: info
message: class that implements IHttp2Server
rule:
  kind: declClass
  regex: ^class\(TInterfacedObject, IHttp2Server\)' src/
```

This reports exactly `src/Http2Server.Server.pas:61`. Broaden the
expression to list every `TInterfacedObject` descendant: `regex:
^class\(TInterfacedObject,` (28 matches across `src/`). Test files match
too — pass `test/` to include them.

A full-text pattern (`type _NAME = class(...) $$$BODY end;`) also parses,
but it is unreliable in this tree: a `///` doc comment between the
`type` keyword and the class — the normal documented style here —
silently stops the match. No strictness level fixes this. Prefer the
rule above. (`find_code_by_rule` over MCP takes the same rule text.)

## Worked example: find call sites by kind (statement-level)

Bare pattern text for a call like `_OBJ.Free()` does not parse standalone
(see gotcha #2 above) — match by kind instead. For a parameterless call
such as `FLock.Free;`, constrain `exprDot` (see gotcha #3 above) with a
YAML rule:

```bash
ast-grep scan --custom-languages allow -c sgconfig.yml --inline-rules 'id: free-call
language: pascal
severity: info
message: parameterless Free call
rule:
  kind: exprDot
  regex: \.Free$' src/
```

For calls with parentheses, `exprCall` is the right kind:

```bash
ast-grep run --custom-languages allow --lang pascal -k exprCall src/ | grep '\.Create('
```

`grep` on the CLI output is a stopgap for a quick look, not the real
filter. For anything past "does this substring appear in an `exprCall`
node," use a YAML rule (`ast-grep scan`) with a `has`/`field`/`regex`
constraint on the callee instead.

## If the language does not load / patterns silently do not match

- Confirm the library exists:
  `ls third_party/tree-sitter-pascal/libtree-sitter-pascal.dylib` — if
  missing, run `task vendor:tree-sitter-pascal` (it clones *and* builds;
  see that task in `Taskfile.yaml`).
- Confirm the opt-in is present: without `--custom-languages allow` the
  CLI prints `Warning: custom languages are ignored ...` on `scan`, or
  silently matches nothing on `run`.
- Confirm `-c sgconfig.yml`, when it is used, comes **after** the `run`
  subcommand, not before it. Before `run` it is read as a search path.
- `Warning: Pattern contains an ERROR node` almost always means gotcha
  #1, #2 or #3 above, not a broken setup — check the metavariable sigil,
  whether a bare statement/expression fragment is matched, and whether a
  parameterless call needs `exprDot` before assuming misconfiguration.

## Output format

Report results the same shape as `ctags-nav`:
```
<pattern/kind description>  →  path/to/File.ext:42-58
```
