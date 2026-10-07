---
name: ast-grep-nav
description: Structural (AST-based) code search and rewrite using ast-grep, registered project-wide as an MCP server, covering both Pascal (backend, via a vendored custom grammar) and TypeScript/TSX (view-app/UIX, built in). Use when a search is about code *shape* (find every class implementing an interface, every call to a given method regardless of receiver name, every component calling a given hook, a rewrite across many call sites) rather than an exact symbol name or a plain text/string match.
---

# ast-grep Structural Search

This project registers ast-grep as a project-scoped MCP server (`.mcp.json`, server name `ast-grep`), backed by the
`ast-grep` CLI (installed via `brew install ast-grep`). Any MCP-compatible agent gets four tools: `find_code`,
`find_code_by_rule`, `test_match_code_rule`, `dump_syntax_tree`. If MCP tools aren't available in your context, the
same thing is reachable via Bash using the `ast-grep` CLI directly — every example below shows both forms.

Two languages are covered, with very different setup and sharp edges — jump to the section for the code you're
searching:

- **[Pascal](#pascal-units-appspas-lpr)** (`units/`, `apps/*.pas`, `*.lpr`) — a *custom* ast-grep language, backed
  by a vendored grammar. Has real gotchas; read that section before writing a pattern.
- **[TypeScript / TSX](#typescript--tsx-appsview-app)** (`apps/service/view-app`) — *built in* to ast-grep, zero setup.
  None of the Pascal gotchas apply.

## When to use this

Three tools cover overlapping ground; pick by what you actually know:

- **`ctags-nav`** — you know the exact name of a class/interface/record/method/unit and want its definition.
  Fastest, most precise, use it first for name lookups.
- **`ast-grep` (this skill)** — you know the *shape* of the code, not a specific name: "every class that
  implements `IRepository`", "every place `.save()` is called", "rewrite this call pattern everywhere it occurs".
  Structural match beats text search because it ignores whitespace/formatting differences and won't false-positive
  on a substring match inside a comment or string literal.
- **`rg`** — plain text: string literals, comments, log messages, or when you're not sure of the shape and just
  want to scan for a substring.

## Pascal (units/, apps/*.pas, *.lpr)

Backed by a vendored `tree-sitter-pascal` grammar (`.vendor/tree-sitter-pascal`, built by
`task vendor:tree-sitter-pascal`) registered as a custom language in `sgconfig.yml` at the repo root.

### Gotchas (read before writing a pattern)

tree-sitter-pascal is a custom, non-built-in language for ast-grep, and it has two sharp edges that don't show up
with ast-grep's built-in languages:

1. **Metavariables use `_NAME`, not `$NAME`.** Pascal's hex-literal syntax (`$FF`) collides with ast-grep's default
   `$METAVAR` sigil, so `sgconfig.yml` sets `expandoChar: _` for the `pascal` language. Every metavariable in a
   Pascal pattern is `_UpperCaseName`, e.g. `_OBJ`, `_NAME`, `_IFACE` — not `$OBJ`.
2. **Bare statement/expression pattern strings usually fail to parse on their own.** Unlike JS/Python, tree-sitter-
   pascal doesn't give ast-grep a way to auto-wrap a lone fragment like `_OBJ.save()` or `event.save()` in valid
   context — you'll get `Error: Cannot parse query as a valid pattern` even for patterns that are clearly valid
   Pascal in context. Two ways around it:
   - For **declarations** (types, classes), write the full enclosing shape in the pattern text — `type` keyword
     through `end;` — rather than just the header. See the worked example below.
   - For **statements/expressions** (a specific call shape, wherever it occurs), match by **AST kind** instead of
     pattern text — `--kind <KIND>` on the CLI, or `find_code_by_rule`/`test_match_code_rule` with a YAML
     `rule: {kind: ..., ...}` over MCP. This matches every node of that kind and doesn't require the fragment
     itself to be independently parseable.
   Use `dump_syntax_tree` (MCP) or `ast-grep run --lang pascal --debug-query=ast -p '<snippet>' /dev/null` (CLI)
   to see the actual node kinds tree-sitter-pascal uses (they're distinctive — `declClass`, `declType`, `exprCall`,
   `exprDot`, `kClass`, etc. — not the names you'd guess from a mainstream grammar).

### Worked example: find domain-object class declarations

Find every class implementing a given interface (the shape this codebase's [domain layer](../../../doc/base/technical/domain/domain-layer.md)
uses everywhere — `TFoo = class(TInterfacedObject, IFoo) ... end;`):

CLI:
```bash
ast-grep run -c sgconfig.yml --lang pascal -p 'type
  _NAME = class(TInterfacedObject, _IFACE)
  $$$BODY
  end;' units/ apps/
```

MCP (`find_code`): pattern `type\n  _NAME = class(TInterfacedObject, _IFACE)\n  $$$BODY\n  end;`, language `pascal`.

`_NAME`/`_IFACE` bind the class/interface identifiers; `$$$BODY` captures the member list (fields/methods) as a
multi-node wildcard. Narrow to a specific interface by writing it literally instead of `_IFACE`, e.g.
`class(TInterfacedObject, IRepository)`.

### Worked example: find call sites by kind (statement-level)

Bare pattern text for a call like `_OBJ.save()` won't parse standalone (see gotcha #2 above) — match by kind
instead:

CLI:
```bash
ast-grep run -c sgconfig.yml --lang pascal -k exprCall units/ apps/ | grep '\.save('
```

For anything past "does this substring appear in an `exprCall` node," reach for a YAML rule
(`find_code_by_rule`/`ast-grep scan`) with a `has`/`field`/`regex` constraint on the callee instead of piping
through `grep` — `grep` on the CLI output is a stopgap for a quick look, not the real filter.

### If the language doesn't load / patterns silently don't match

- Confirm the dylib exists: `ls .vendor/tree-sitter-pascal/libtree-sitter-pascal.dylib` (macOS) — if missing, run
  `task vendor:tree-sitter-pascal` (it clones *and* builds; see that task in `Taskfile.yaml`).
- Confirm `sgconfig.yml` is actually being picked up: the CLI needs `-c sgconfig.yml` **after** the `run`
  subcommand (`ast-grep run -c sgconfig.yml ...`), not before it, despite `ast-grep --help`'s top-level listing —
  putting it before `run` produces a confusing "unexpected argument" error from clap's default-subcommand
  handling.
- `Warning: Pattern contains an ERROR node` almost always means gotcha #1 or #2 above, not a broken setup —
  check the metavariable sigil and whether you're matching a bare statement/expression fragment before assuming
  something's misconfigured.

## TypeScript / TSX (apps/service/view-app)

TypeScript and TSX are **built in** to ast-grep — no `sgconfig.yml` entry, no vendored grammar, nothing to build.
`--lang typescript` or `--lang tsx` (CLI) / `language: typescript`/`tsx` (MCP) just work against `apps/service/view-app/src`
today. `view-app` is pure TypeScript/TSX — no plain `.js`/`.jsx` in its actual source (a naive `.js` count elsewhere
in the tree is almost always `node_modules`, not real source; exclude it).

**None of the Pascal gotchas above apply here**: metavariables are plain `$NAME`/`$$$NAME` (no `expandoChar` —
that workaround was specifically for Pascal's `$FF`-style hex literals), and bare statement/expression/JSX
fragments parse standalone fine, no `--kind`/rule-based workaround needed.

### Worked examples (validated against real view-app source)

Find every call to a specific hook, anywhere:
```bash
ast-grep run --lang tsx -p 'useEffect($$$)' apps/service/view-app/src
```

Find every `useQuery` call (this codebase's TanStack Query usage) to see the shape of `queryKey`/`queryFn` across
the app:
```bash
ast-grep run --lang tsx -p 'useQuery({$$$})' apps/service/view-app/src
```

Find every use of a specific MUI component, including its props and children:
```bash
ast-grep run --lang tsx -p '<Button $$$PROPS>$$$CHILDREN</Button>' apps/service/view-app/src
```

Find every top-level function component declaration:
```bash
ast-grep run --lang tsx -p 'export function $NAME($$$PROPS) { $$$BODY }' apps/service/view-app/src
```

MCP (`find_code`): same pattern strings, `language: "tsx"`.

## Output format

Report results the same shape as `ctags-nav`:
```
<pattern/kind description>  →  path/to/File.ext:42-58
```
