{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, toolchain, fpc, openssl, build, platform
notes:
  - This document records the compiler, the platform and the build.
scope: The compiler and platform facts, the build flags, the TLS libraries, the dependency bootstrap, the test suite and the deliberate gaps.
primary_types: []
db_tables: []
related_docs:
  - doc/design/fpc-runtime.md
  - doc/verification/validation.md
invariants:
  - The pinned compiler is Free Pascal 3.2.4.
  - OpenSSL 3 is a run-time dependency and is not linked into the binary.
---
}

# Toolchain and environment

Locked toolchain facts for the HTTP/2 server library. A later change corrects
this file in the same change and notes the correction.

## Compiler and platform

| Fact | Value | Evidence |
|---|---|---|
| Compiler | `fpc 3.2.4` (`ppca64`), macOS aarch64 | `fpc -iV`, `fpc -iTP`, `fpc -iTO` |
| Unit search root | `/usr/local/lib/fpc/3.2.4/units/aarch64-darwin/` | `Makefile:21`, `fpc -iTP`/`fpc -iTO` |
| Mode | `{$mode delphi}{$H+}`, `{$modeswitch advancedrecords}`, `{$interfaces com}` | `src/Http2Server.pas:20-23`, `test/Http2Server.TestRunner.pas:16-18` |
| Thread manager | `{$IFDEF UNIX}cthreads,{$ENDIF}` **before** threaded units | `test/Http2Server.RunTests.pas:16-18`, `test/Http2Server.TestRunner.pas:27-29` |

The `Makefile` and `Taskfile.yaml` derive the unit directory from
`fpc -iV` (version), `fpc -iTP` (target CPU) and `fpc -iTO` (target OS). The
Darwin default holds `/usr/local/lib/fpc/3.2.4/units/aarch64-darwin`. The
Linux default holds `/usr/lib/fpc/<version>/units/<cpu>-<os>`. The variable
`FPC_UNITS` overrides each default (`Makefile:13-26`,
`Taskfile.yaml:33-50`).

## Build flags

The shared flags are `-O2 -vw -Mdelphi -Fu./src -Fu$(FPC_UNITS)/fcl-fpcunit`
plus the four mORMot2 unit directories `core`, `lib`, `net` and `crypt`
(`Makefile:28-34`, `Taskfile.yaml:63`). The `-O2` flag optimises; `-vw` prints
warnings; `-Mdelphi` selects the Delphi mode; `-Fu` adds a unit directory.
The library target adds `-Cn` (omit the linker stage) and `-FE$(BIN)` (place
the output in the `bin/` directory) (`Makefile:44-45`).

## TLS and ALPN

| Fact | Value | Evidence |
|---|---|---|
| mORMot checkout | `third_party/mORMot2` at `b2b195da1e0580058672a88620ef71bb47283eb1` | `Taskfile.yaml:53`, `git -C third_party/mORMot2 rev-parse HEAD` |
| mORMot unit dirs | `core`, `lib`, `net`, `crypt` | `Makefile:34`, `Taskfile.yaml:63` |
| `OPENSSL_LIBPATH` (Darwin) | `/opt/homebrew/opt/openssl@3/lib` | `Makefile:22`, `Taskfile.yaml:54-62` |
| `OPENSSL_LIBPATH` (Linux) | `/usr/lib/x86_64-linux-gnu` | `Makefile:25`, `Taskfile.yaml:54-62` |

The variable `OPENSSL_LIBPATH` names the directory of the OpenSSL 3 library.
`mormot.lib.openssl11.pas` loads the library from this directory at run time.
The `Makefile` exports the variable, so a test binary inherits it
(`Makefile:33`, `Taskfile.yaml:66-67`).

The server library uses mORMot2 for the TLS and ALPN layer. The language and
TLS facts are recorded in `doc/design/fpc-runtime.md`.

## Dependency bootstrap

`task setup:deps` clones `https://github.com/synopse/mORMot2.git` into
`third_party/mORMot2` and checks out the pinned revision
(`Taskfile.yaml:76-93`). The task is idempotent: a directory that is already
at the revision prints `already at <rev>` and changes nothing. A fresh clone
runs the task once; every later run is a no-op.

The directory `third_party/` is ignored by version control (`.gitignore`,
section "Vendored third-party checkouts"). The pinned revision is the
authority for the dependency, not the directory contents.

## The test suite

`make test` builds `src/Http2Server.pas`, then builds
`test/Http2Server.RunTests.pas`, then runs the binary with
`--all --format=plain --sparse` (`Makefile:50-52`). The runner is fpcunit
with `consoletestrunner` (`test/Http2Server.RunTests.pas:18`). The
registration unit `Http2Server.TestRunner` exposes `RegisterTests`, which adds
one named suite to the global test registry
(`test/Http2Server.TestRunner.pas:35-41`). The suite holds no test case until
the server units exist. An empty suite exits with code 0.

The runner registration order is important. `RegisterTests` adds a named
`TTestSuite` to `GetTestRegistry` before `TTestRunner.Run` reads the registry
(`test/Http2Server.RunTests.pas:22-32`). A suite that is absent from the
registry is invisible to the runner.

## Open-file-limit prerequisite

The seam test opens 10,000 connections in one process. The per-process
open-file limit is raised before that test runs. The `Taskfile.yaml` header
documents the setting, and the task `setup:limits` reports the platform
ceiling (`Taskfile.yaml:14-30`, `Taskfile.yaml:95-114`).

| Platform | Soft limit command | Hard ceiling |
|---|---|---|
| macOS | `ulimit -n 20000` | `sysctl kern.maxfilesperproc` (about 61440) |
| Linux | `ulimit -n 20000` | `cat /proc/sys/fs/file-max`, and `nofile` in `/etc/security/limits.conf` |

A limit below the connection count makes the test fail with `EMFILE`, not with
a protocol error.

## Linux amd64 (deliberate gap)

Linux amd64 was not exercised in this environment. The acceptance record
requires an FPC 3.2.4 build and an empty-suite run on Linux amd64. This host
is macOS aarch64 (`fpc -iTP` reports `aarch64`, `fpc -iTO` reports `darwin`).
Docker on this host runs `linux/amd64` through an emulator: `docker run --rm
--platform linux/amd64 alpine:latest uname -m` reports `x86_64`
(2026-10-08). The emulator is therefore not the obstacle.

No amd64 FPC 3.2.4 toolchain is available here for a quick run:

- The public `fpc` image carries no `3.2.4` tag (`docker run fpc:3.2.4`
  reports `pull access denied`; `docker search fpc`, 2026-10-07).
- The `freepascal/fpc` tags stop at `3.2.2`
  (`https://hub.docker.com/v2/repositories/freepascal/fpc/tags`, 2026-10-07).
- `debian:sid` offers `3.2.2+dfsg-51` as its newest `fpc` candidate
  (`apt-cache policy fpc`, 2026-10-08), and
  `https://sources.debian.org/api/src/fpc/` lists `3.2.2+dfsg-51` as the
  newest version in any suite. No suite publishes `3.2.4`.
- Launchpad reports `3.2.2+dfsg-51` as the newest published `fpc` source for
  Ubuntu (`getPublishedSources`, 2026-10-08). No release publishes `3.2.4`.
- Every upstream tarball for `x86_64-linux` fails:
  `https://sourceforge.net/projects/freepascal/files/Linux/3.2.4/fpc-3.2.4.x86_64-linux.tar/download`
  returns HTTP 404, the same URL with `.tar.gz` returns HTTP 404,
  `https://downloads.freepascal.org/fpc/dist/3.2.4/x86_64-linux/fpc-3.2.4.x86_64-linux.tar`
  returns HTTP 403, and
  `https://ftp.freepascal.org/pub/fpc/dist/3.2.4/x86_64-linux/fpc-3.2.4.x86_64-linux.tar`
  returns an empty response (2026-10-08).

The Linux amd64 run is therefore a recorded gap, not a completed task, and
the gap has two halves: no host, and no published toolchain for a host.

A future run needs an amd64 host (or an amd64 emulator that starts an FPC
3.2.4 toolchain) with FPC 3.2.4 and OpenSSL 3. The unit directory is then
`/usr/lib/fpc/3.2.4/units/x86_64-linux` for a distribution package. The Linux
defaults in the `Makefile` and `Taskfile.yaml` (`Makefile:23-25`,
`Taskfile.yaml:42-50`, `Taskfile.yaml:54-62`) are unverified on hardware until
that run happens.

## Reproduce commands

```sh
fpc -iV                       # 3.2.4
fpc -iTP                      # aarch64
fpc -iTO                      # darwin
task setup:deps               # idempotent mORMot2 pin
make test                     # exit code 0
task test                     # exit code 0
```
