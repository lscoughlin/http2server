{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, fpc, compiler-mode, thread-manager, runtime
notes:
  - This document records the Free Pascal facts the library rests on.
scope: The compiler modes, the thread manager, the verified runtime facts, the build line and the file header rule.
primary_types: []
db_tables: []
related_docs:
  - doc/design/architecture.md
  - doc/verification/toolchain.md
invariants:
  - The library compiles in the Delphi mode.
  - The thread manager comes from mORMot2 and not from a program unit.
---
}

# FPC runtime and language facts

The server library is Object Pascal for Free Pascal 3.2.4. This document
records the compiler modes and the verified language facts that the build
line and the test harness rely on. The facts were verified on `fpc 3.2.4`
(`ppca64`), macOS aarch64.

## Compiler modes

Every unit and program opens with the same directives
(`src/Http2Server.pas:20-23`, `test/Http2Server.TestRunner.pas:16-18`,
`test/Http2Server.RunTests.pas:14`):

```pascal
{$mode delphi}
{$H+}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}
{$interfaces com}
```

`{$mode delphi}` selects the Delphi dialect. `{$H+}` selects long strings.
`{$modeswitch advancedrecords}` permits methods and visibility inside
records. `{$modeswitch typehelpers}` permits type helpers. `{$interfaces com}`
selects reference-counted CORBA-style interfaces, so an interface variable
releases its object when the last reference leaves scope.

The Delphi mode is required for generic methods. Under `{$mode objfpc}`, a
generic method does not parse even with `{$modeswitch genericmethods}`: the
compiler reports `Syntax error, ";" expected but "<" found`. The server
design uses generic code, so the mode is fixed.

## Thread manager

A program pulls in the Unix thread manager before any unit that uses threads
(`test/Http2Server.RunTests.pas:16-18`,
`test/Http2Server.TestRunner.pas:27-29`):

```pascal
uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, consoletestrunner, Http2Server.TestRunner;
```

Without `cthreads`, a threaded binary aborts at run time with
`This binary has no thread support compiled in ... Runtime error 232`. The
directive places `cthreads` first in the `uses` clause, because a unit that
is compiled earlier captures the thread manager state at that point.

## Verified Free Pascal facts

These results come from the sibling client's probe programs, which were
compiled and run against the same toolchain. The server inherits them.

| Assumption | FPC 3.2.4 result |
|---|---|
| `TThreadedQueue<T>` | absent; the server builds a blocking queue from `TQueue<T>` |
| `TMonitor` | absent; a `TCriticalSection` guards shared state |
| `TEvent` / `TSimpleEvent` | raise `ESyncObjectException` on macOS; `RTLEvent` is used instead |
| `TStringList.Remove` | absent; `IndexOf` plus `Delete` is used |
| interface reference counting | verified; `TInterfacedObject.Destroy` runs when the last interface reference is cleared |
| generic class and generic method | work under `{$mode delphi}` |

## The build line

The `Makefile` compiles `src/Http2Server.pas` with `-Cn` and `-FE$(BIN)`
(`Makefile:44-45`). `-Cn` omits the linker stage, so the compiler produces
`.ppu` and `.o` outputs but no executable. `-FE$(BIN)` places those outputs in
the `bin/` directory. The `Makefile` target names `bin/libhttp2server.a`, which
is the conventional library name; the actual product of `-Cn` is the compiled
unit.

The test target compiles `test/Http2Server.RunTests.pas` with the `./test`
directory on the unit search path, then runs the binary
(`Makefile:50-52`). The same flags serve both targets, so a header change in
one unit is visible to the other.

## The facade unit

`src/Http2Server.pas` is the public facade of the library
(`src/Http2Server.pas:12-18`). The unit declares no type and no routine yet,
because the server surface does not exist. The unit exists so that the build
line and the test runner link a real library unit from the first change. The
planned units of the library are recorded in `doc/design/` as they arrive.

## File headers

Each Pascal file starts with a pasdoc comment that wraps YAML front matter
(`src/Http2Server.pas:1-27`). The front matter holds a `license` key and a
`copyright` key. The licence value is the SPDX expression of the library,
`LGPL-2.1-only WITH Independent-modules-exception`. The file `NOTICE` names
the full licence name and the third-party components.
