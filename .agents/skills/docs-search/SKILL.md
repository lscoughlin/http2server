---
name: docs-search
description: Search the indexed documentation corpus (doc/**/*.md, *.yaml, plus units/**/*.pas and apps/**/*.pas) via the Clarity MCP server. Use this before grepping doc/ by hand to find architecture notes, data model definitions, or component READMEs.
---

# Docs Search Skill

This project indexes `doc/` and the Pascal sources into one Clarity index (`docs`), served by the
`clarity` MCP server configured in `.mcp.json` and `.clarity/config.yaml`.

## When to use this

Prefer this over `rg`/`grep` as the **first** step when looking for architecture notes, data model
definitions, component READMEs, or any other prose under `doc/`. It ranks results by relevance
instead of just matching lines. Fall back to `rg`/`grep` only if a search here turns up nothing
useful.

Because the `docs` index also covers `units/**/*.pas` and `apps/**/*.pas`, it is also useful for
text queries that should turn up both a doc and the code it describes in one search — but for a
known symbol name or a structural code shape, `ctags-nav`/`ast-grep-nav` are still the right tool
(see AGENTS.md Section 6).

## Searching the index

Prefer the `mcp__clarity__search` MCP tool directly:

```json
{"index": "docs", "query": "your query"}
```

- `index` is always `"docs"` — the only index this project's `.clarity/config.yaml` defines.
- `syntax` (optional): `text` (plain words, default), `raw` (Lucene syntax), or `vector` (semantic
  search).
- `top_n` (optional): maximum hits to return.

From a shell, the equivalent is the `clarity` CLI:

```bash
clarity query docs "your query"
```

- `-n, --top-n=<N>` to cap hit count.
- `--query-syntax=text|raw|vector` for the same syntax options as the MCP tool.

## Re-indexing

The index lives under `.clarity/index/` (gitignored — rebuilt locally) and is driven by the
tracked `.clarity/config.yaml`. Re-index after `doc/` or the Pascal sources change:

```bash
clarity index -d .
```

If a search errors because the index is missing, run this first.
