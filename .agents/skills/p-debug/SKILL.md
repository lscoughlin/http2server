---
name: p-debug
description: >-
  Debug FreePascal/FPC crashes, test failures, leaks, and slowness. Use when
  diagnosing segfaults, exceptions, wrong results, heap corruption, memory
  leaks, or performance; or when the user mentions debug, Lazarus, fpdebug,
  heaptrc, Valgrind, gprof, Instruments, or profiling.
---

# p-debug — FPC debugging

Read this skill before invoking `fpc` or guessing at debugger flags. Rebuild
through `task` wrappers so every package picks up the same extra flags.

## When to use

- A unit test or app crashes, hangs, asserts, or returns the wrong result
- Suspected leak, use-after-free, double-free, or heap corruption
- A routine is slow and needs a profile
- The user asks to debug, trace, Valgrind, heaptrc, or profile Pascal code

## Classify first

| Symptom | Path |
|---|---|
| Crash, SIGSEGV, hang, wrong value, failing test | Interactive debug |
| Leak, corruption, use-after-free | Memory |
| Slow / hot path | Profile |

Prefer the **smallest binary that reproduces**: a package `*:test` testrunner
over `web-app` / `core-app` / `async-app`. Apps need their usual config, ports,
and Docker Postgres.

## Locate the code

Once you have a backtrace frame, exception line, or suspect symbol, follow the
`ast-grep-nav` and `ctags-nav` skills before changing anything: `ast-grep-nav`
first for structural/shape searches (every caller of a method, every place a
leak-prone pattern — e.g. an unchecked `.Free` — appears), `ctags-nav` for the
exact definition of a known symbol name, `rg` for plain text.

## Rebuild — never invoke `fpc` directly

Production Taskfiles compile `fpc -MObjFPC -Scghi` with **no** debug info.
Flag changes do not invalidate `.o`/`.ppu`, so wrappers pass `-B`.

```bash
task debug -- core:test          # DWARF3 + lineinfo, -O-  (Lazarus/fpdebug)
task heaptrc -- core:test        # debug + heaptrc
task profile -- core:test        # gprof (-pg -g -O1)
task valgrind -- path/to/binary  # Linux memcheck only
task valgrind:docker -- "…"      # debian:bookworm (compile inside the container)
```

`<task>` is any existing target (`core:test`, `persistence:test`,
`web-app:build`, `test:units`, …). Wrappers set `FPC_EXTRA_FLAGS` and re-run
that target. Discover names with `task --list`.

| Wrapper | `FPC_EXTRA_FLAGS` | Also |
|---|---|---|
| `debug` | `-B -gw3 -gl -O-` | Lazarus/fpdebug, Instruments, Valgrind rebuild |
| `heaptrc` | `-B -gw3 -gl -gh -O-` | `HEAPTRC=keepreleased,log=heap.trc` |
| `profile` | `-B -pg -g -O1` | writes `gmon.out` next to cwd of the binary |
| `valgrind:docker` | (runs `debug`/`valgrind` inside the image) | `debian:bookworm` — must compile in-container |

Do **not** combine `-gh` with Valgrind or with `-pg`.

After a debug session, `task <pkg>:clean` (or `task clean`) before a normal
rebuild so debug/profile objects are not reused.

## Interactive debug (default: Lazarus / fpdebug)

Each `.lpr` has a sibling `.lpi` with the same `-Fu`/`-Fi`/`-d` as its
Taskfile, DWARF3, lineinfo, and `-O-`. Open the `.lpi` in Lazarus and Run
under **fpdebug**. Do not create a new project.

| Program | Project |
|---|---|
| Unit tests | `units/app/<pkg>/test/testrunner.lpi` (persistence e2e: `…/test/integration/testrunner.lpi`) |
| web-app | `apps/service/web-app/src/webapp.lpi` |
| core-app | `apps/service/core-app/src/coreapp.lpi` |
| async-app | `apps/service/async-app/src/asyncapp.lpi` |
| tsqltool / tdssqlgen | `apps/util/<name>/<name>.lpi` and `apps/util/<name>/test/testrunner.lpi` |

If Taskfile search paths change, regenerate: `task generate:lpi`.

You can also `task debug -- <pkg>:test` and debug that binary from Lazarus
(Run → Run Parameters) if the IDE rebuild is inconvenient.

If the user is not at Lazarus, or you need a backtrace in-agent, use the
**same debug binary**:

```bash
# macOS
lldb -- ./test/bin/testrunner
# (lldb) breakpoint set --file app.core.id.pas --line 42
# (lldb) run
# (lldb) bt
# (lldb) frame variable

# Linux
gdb --args ./test/bin/testrunner
# (gdb) break app.core.id.pas:42
# (gdb) run
# (gdb) bt
# (gdb) info locals
```

`-gl` is required for useful FPC exception line info. Reproduce once under the
debugger before changing code.

## Memory

### macOS (default): heaptrc

Valgrind is **not** used on macOS in this repo.

```bash
task heaptrc -- core:test
```

`heap.trc` is written in the **task working directory** (the included
Taskfile `dir`, e.g. `units/app/core/heap.trc`). Read that file. Unreleased
blocks at process exit are leaks; `keepreleased` helps catch use-after-free.

Optional `HEAPTRC` values (override when invoking `task heaptrc`):
`keepreleased`, `log=path`, `haltonerror`, `haltonwarning`, `info:n`, `disabled`.

A growing process that heaptrc does not blame may be an FPC memory manager
freelist or a cache — confirm with a second run and by checking caches /
connection pools before calling it a leak.

### Linux: Valgrind memcheck

**Image:** `debian:bookworm` (wrapper image `tdbank-fpc-valgrind` from
`.ai/docker/fpc-valgrind/Dockerfile`). Chosen because Valgrind is first-class
on Debian amd64 and aarch64, `fpc` 3.2.2 is close to this repo's 3.2.4, and
Apple Silicon Docker can use `linux/arm64` natively — do not pin
`linux/amd64`. Compile **inside** the container; Darwin binaries cannot be
valgrind'd. Linux `.o`/binaries overwrite the host `test/bin` — `task
<pkg>:clean` afterwards.

```bash
task valgrind:docker -- "task debug -- core:test && task valgrind -- units/app/core/test/bin/testrunner"
```

On a native Linux host, rebuild **without** `-gh`, then memcheck:

```bash
task debug -- core:test
task valgrind -- units/app/core/test/bin/testrunner
```

`task valgrind` refuses to run unless `uname` is Linux. Equivalent manual
invocation:

```bash
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes \
  --error-exitcode=1 ./test/bin/testrunner
```

Expect RTL / `cthreads` still-reachable noise. Treat **definitely lost** and
invalid reads/writes as real. Do not add a suppression file unless the user
asks.

## Profile

### macOS (default): Instruments / `sample`

Use a **debug** build, not `-pg` (gprof instrumentation distorts Instruments).

```bash
task debug -- web-app:build
xcrun xctrace record --template 'Time Profiler' --output profile.trace \
  --launch -- apps/service/web-app/bin/web-app
# or attach to a running PID:
sample <pid> 10 -file sample.txt
```

Ask the user to open `profile.trace` in Instruments if you cannot interpret
the GUI. Prefer `sample` output when working headless.

### gprof

```bash
task profile -- core:test
# PATH, or Homebrew keg-only binutils on macOS:
gprof ./test/bin/testrunner gmon.out > gprof.txt
# /opt/homebrew/opt/binutils/bin/gprof ./test/bin/testrunner gmon.out > gprof.txt
```

`gmon.out` is created in the process cwd. Resolve `gprof` in this order:
`command -v gprof`, then `/opt/homebrew/opt/binutils/bin/gprof` (Homebrew
`binutils` is keg-only). If that path is missing: `brew install binutils`.
The `profile` task prints which binary it found. If neither exists, use
Instruments/`sample`. On Linux, gprof is the default profiler.

## Report back

State: binary and task used, wrapper (`debug` / `heaptrc` / `profile` /
`valgrind`), host OS, and the evidence (exception + line, lldb/gdb `bt`,
heaptrc unreleased block, Valgrind definitely-lost, gprof/sample hot frames).
Then the suspected cause and the smallest code change.

## Ask the user when

- Lazarus/fpdebug is needed (breakpoints, watches, stepping)
- Instruments GUI interpretation is needed
- The repro needs credentials, a live DB, or a long-running worker
- Valgrind must run and Docker/`debian:bookworm` cannot be used
- You are about to change default (non-wrapper) Taskfile compiler flags
