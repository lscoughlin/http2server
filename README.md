# http2server

An HTTP/2 server for Free Pascal and mORMot2. The library speaks HTTP/2 over
clear text with prior knowledge (`h2c`) and over TLS with the ALPN name `h2`.

The design separates a few non-blocking IO threads from a pool of ordinary
blocking handler threads. The handler contract is synchronous, so a caller
writes the same code it writes for a threaded server. The seam between the two
sides is narrow and keeps the IO thread out of the handler code.

## Licence

This product is licensed under the **GNU Lesser General Public License,
version 2.1, with the Free Pascal linking exception**.

The Software Package Data Exchange (SPDX) licence expression is:

    LGPL-2.1-only WITH Independent-modules-exception

Copyright 2026 Liam Seamus Coughlin.

The file `LICENSE` holds the full text of the LGPL and the exception. The file
`NOTICE` names the third-party components: mORMot2, OpenSSL, and the origin of
the copied protocol units.

## Where to read more

- `doc/README.md` is the route map of the documentation.
- `doc/design/architecture.md` holds the shape of the library.
- `doc/design/public-api.md` holds the surface a caller uses.
- `doc/verification/validation.md` holds the conformance record.
- `doc/verification/toolchain.md` holds the compiler and the build.

## Build

```sh
task setup:deps   # clone the pinned mORMot2 checkout
task build        # build the library unit
task test         # run the fpcunit suite
task docs:check   # check the documentation tree
task validate     # run the external conformance tools
```

The pinned compiler is Free Pascal 3.2.4. OpenSSL 3 is needed at run time.
