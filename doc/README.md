{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, documentation, index, map
notes:
  - This file is the root of the documentation tree.
  - Every other document is reachable from this file.
scope: The route map of the documentation tree, the licence and the third-party components.
primary_types: []
db_tables: []
related_docs:
  - doc/design/architecture.md
invariants:
  - Every document in doc/ is linked from this file.
  - The third-party components are named in the file NOTICE.
---

}
# The HTTP/2 server documentation

This file is the route map of the documentation. The library is an HTTP/2
server for Free Pascal and mORMot2. A caller adds the unit
`src/Http2Server.pas` to a uses clause and builds a server.

The tree has two parts. The directory `doc/design/` holds the design of the
library. The directory `doc/verification/` holds the records of the builds
and the runs.

## Design

The design documents start with the two documents that hold the shape of the
whole library.

| Document | Content |
| --- | --- |
| [architecture](design/architecture.md) | The two thread pools, the seam between them, the unit layout and the growth of the code. |
| [threading](design/threading.md) | The thread roles, the work of each role, and the rules that keep the roles apart. |

The remaining design documents follow the path of one request through the
library.

| Document | Content |
| --- | --- |
| [configuration](design/configuration.md) | The factory record, the option records it carries and the validation rules. |
| [public-api](design/public-api.md) | The factory, the server, the handler contract and the observation events. |
| [lifecycle](design/lifecycle.md) | The life of one server from `Start` to `Stop`, the GOAWAY broadcast and the drain wait. |
| [seam](design/seam.md) | The handler-facing interfaces, the blocking waiter, the cancel workers and the per-stream buffers. |
| [admission](design/admission.md) | The bounded queue, the handler pool, the refusal modes and the counters. |
| [connection](design/connection.md) | The connection core: bytes in, frames out, stream states and HPACK state. |
| [output](design/output.md) | The response path: encode under the connection lock, then frame the bytes. |
| [protocol](design/protocol.md) | The five protocol units, the server changes to them, and the errors they raise. |
| [limits](design/limits.md) | The token buckets that bound the work a peer may ask for. |
| [io-pool](design/io-pool.md) | The mORMot2 async subclasses, the write wake-up and the thread rule. |
| [tls](design/tls.md) | The route to ALPN, the TLS plug-in of a connection and the OpenSSL binding. |
| [fpc-runtime](design/fpc-runtime.md) | The Free Pascal facts the library rests on: compiler modes, the thread manager and the build line. |
| [future-coroutines](design/future-coroutines.md) | The deferred coroutine option, the research result and the open items. |

## Verification

The verification documents record what ran and what did not run.

| Document | Content |
| --- | --- |
| [toolchain](verification/toolchain.md) | The compiler, the platform, the build flags, the dependency bootstrap and the deliberate gaps. |
| [validation](verification/validation.md) | The conformance runs, the comparison with the C and FreePascal implementations, and the recorded gaps. |

## The example programs

The directory `examples/` holds small servers that the verification runs use.
The directory `tools/` holds the scripts that start a server and drive the
external tools. The command `task validate` repeats every conformance check.
The command `task docs:check` holds the rules of this tree.

## Licence

This library is licensed under the GNU Lesser General Public License, version
2.1, with the Free Pascal linking exception. The SPDX expression is
`LGPL-2.1-only WITH Independent-modules-exception`. The file `LICENSE` holds
the full text, and the file `NOTICE` names the third-party components.

## Where to read first

A reader who is new to the library starts with
[architecture](design/architecture.md). A reader who wants to build a server
continues with [public-api](design/public-api.md) and
[configuration](design/configuration.md).
