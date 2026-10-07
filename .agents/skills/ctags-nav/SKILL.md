---
name: ctags-nav
description: Look up Pascal symbol definitions (class, interface, record, method, unit) via the project's Universal Ctags index before falling back to text search. Use when asked where a type, method, or unit is defined, or to resolve a qualified name like TOrderRepository.FindById.
---

# Ctags Symbol Navigation

This project maintains a Universal Ctags index (`tags`, at repo root) generated from Pascal sources via
`.ctags.d/pascal.ctags`, queried with `readtags`.

## When to use this

Prefer this over `rg`/`grep` as the **first** step when resolving a class, interface, record, method, or unit
definition. It returns an exact `file:line` with kind and signature instead of scanning for text matches. Fall back
to `rg` only if the symbol is not indexed (new/uncommitted code, typo'd name) or you need call sites / string
literals rather than a definition.

## Looking up a symbol

Run from the repo root (default tag file is `tags`):

```bash
readtags -e SymbolName
```

Qualified names work too (ctags emits `--extras=+q` fully-qualified entries):

```bash
readtags -e TOrderRepository.FindById
```

- `-e` / `--extension-fields` adds `kind:`, `typeref:`, and `signature:` to each match — enough to tell a class
  from a method from a unit without opening the file.
- `-i` adds case-insensitive matching; `-p` adds prefix matching for a partial/uncertain name:
  ```bash
  readtags -iep TOrderRepo
  ```
- Multiple hits (e.g. an interface and its implementing class) are normal — read enough of `signature:`/`typeref:`
  to pick the right one, or open both.

## If nothing matches

The `tags` file is regenerated explicitly, not on every build — it can be stale after new code lands:

```bash
task generate:ctags
```

Retry `readtags` after regenerating. If the symbol still isn't indexed (e.g. it's a local variable or something
ctags' Pascal parser doesn't emit — see `.ctags.d/pascal.ctags` for the configured kinds), fall back to:

```bash
rg -n 'SymbolName' --type pascal
```

Use plain `grep` only if `rg` is unavailable.

## Output format

Report results as:
```
SymbolName  →  path/to/File.pas:42  (kind: class|interface|record|member|unit)
```
