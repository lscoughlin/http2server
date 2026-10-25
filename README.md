# http2server

An HTTP/2 server for Free Pascal and mORMot2. The library speaks HTTP/2 over
clear text with prior knowledge (`h2c`) and over TLS with the ALPN name `h2`. A
client that does not speak HTTP/2 gets HTTP/1.1 from the same listener and the
same handler; the factory method `WithHttp11Fallback` turns this off.

Three features go beyond a plain request and response. A handler can detach a stream and serve
it later from any thread, which gives **server-sent events** (`StartSse`) and **WebSocket**
(`AcceptWebSocket`). WebSocket works over HTTP/1.1 (RFC 6455) and over HTTP/2 (RFC 8441)
with one handler code. The examples `sse_clock`, `sse_fanout`, `sse_replay` and `ws_echo` show them.

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
- `doc/design/sse.md` holds the server-sent event stream.
- `doc/design/http1.md` holds the HTTP/1.1 fallback.
- `doc/design/access-log.md` holds the access log: one record per request, written through `WithAccessLogWriter`.
- `doc/design/websocket.md` holds the WebSocket session, the handshakes and the limits.
- `doc/design/mtls.md` holds mutual TLS: the client certificate modes, the trust and the identity.
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

## Mutual TLS

The factory asks a TLS client for a certificate with `WithClientCertMode` on the
TLS options. The mode `ccmOptional` serves a client without a certificate, and
`ccmRequired` refuses it in the handshake. The trust anchors come from
`WithClientCaFile`, and from the system store when `WithClientTrustSystemStore`
is on. A self-signed client certificate is trusted when it is in the CA file. A
handler reads the verified identity from `IServerRequest.ClientCertificate`. The
example `examples/mtls_server.pas` shows a server, and `make mtls-live` runs the
live validation against the sibling client at `../http2client`. A test PKI comes
from `tools/certs/make_mtls_pki.sh`:

```sh
sh tools/certs/make_mtls_pki.sh /tmp/pki
bin/mtls_server /tmp/pki/server.crt /tmp/pki/server.key /tmp/pki/ca.crt
curl --cacert /tmp/pki/ca.crt --cert /tmp/pki/alice.crt --key /tmp/pki/alice.key https://localhost:8443/
```

The pinned compiler is Free Pascal 3.2.4. OpenSSL 3 is needed at run time.
