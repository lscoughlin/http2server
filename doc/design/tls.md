{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls, alpn, openssl
notes:
  - The TLS route and the ALPN binding of the server.
  - The route is option A: the mORMot2 INetTls interface plus one ALPN
    select callback, installed on the server context after the socket binds.
scope: How the server reaches ALPN, and the mORMot2 TLS facts the route rests on.
primary_types:
  - TAlpnSelectCb
  - TSslCtxSetAlpnSelectCb
db_tables: None.
related_docs:
  - doc/design/protocol.md
  - doc/design/fpc-runtime.md
invariants:
  - A client that offers no acceptable ALPN protocol is refused with a
    fatal alert, so no HTTP/1.1 request ever reaches an HTTP/2 code path.
  - The ALPN callback argument outlives every handshake.
---
}
# TLS and ALPN

A TLS connection carries an ALPN extension. The server selects `h2` from the
list that the client offers. A client that does not offer `h2` is refused with
a fatal alert, so the server never receives an HTTP/1.1 request on a
connection it believes to be HTTP/2.

## The route

The server uses the mORMot2 `INetTls` interface, which wraps OpenSSL, and adds
one callback: `SSL_CTX_set_alpn_select_cb`. This route needs no change to
mORMot2. It is the option A of the analysis below.

## mORMot2 facts the route rests on

The following facts come from reading the pinned mORMot2 revision
`2ccea1a0e5d7be85bd3cf68e1fd70e9e603d09cc`. They are the facts that decide the
route, so they are recorded here with their citations.

**Where the server context exists.** `TOpenSslNetTls.AfterBind` creates the
server `SSL_CTX` with `SSL_CTX_new_server`, runs `SetupCtx` on it, and stores
it in the `AcceptCert` field of the `TNetTlsContext` record
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11918-11949`). The
context outlives every connection, and `AfterAccept` reuses it.

**`AcceptCert` is public.** `AcceptCert` is a public field of the
`TNetTlsContext` record (`third_party/mORMot2/src/net/mormot.net.sock.pas:1177`).
A caller that holds the context reaches the server `SSL_CTX` with a pointer
cast, so a hook after `AfterBind` needs no new mORMot2 entry point.

**Where to install the callback.** `DOpenSslNetTlsSetupCtx` runs inside
`AfterBind` and sets only the servername callback
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11938-11943`). It sets
no ALPN select callback, so a caller can install one after `AfterBind` returns.
The server does this through `Http2AlpnAttach`, which reads the context from a
bound `TCrtSocket`.

**The handshake blocks the calling thread.** `AfterAccept` calls
`CheckProc(@SSL_accept, 'AfterAccept SSL_accept')`
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11953-12009`).
`CheckProc` loops on `SSL_accept` and, on a `WANT_READ` or `WANT_WRITE`,
calls `fSocket.WaitFor(100, ne)` (`...:12169-12188`, `...:12146-12167`). The
loop carries a deadline of 5000 ms and raises a timeout exception when it
passes. The calling IO thread therefore blocks inside the handshake, and a
client that opens TCP and sends nothing holds that thread for 5 seconds at
most.

**The stalled-client cost.** Because the handshake blocks its IO thread for up
to 5 seconds, a client that stalls delays only the thread that accepted it.
The async server accepts asynchronously when TLS is on
(`third_party/mORMot2/src/net/mormot.net.async.pas:4387`, `async=false` for the
accept), and the handshake runs at the first read in
`OnFirstReadDoTls` (`...:4244-4266`). A second client still completes its
handshake on another thread.

**How the async server reports no data.** `INetTls.ReceivePending` returns the
bytes held in the TLS buffer, `0` when that buffer is empty but socket-level
data may still be unciphered, and `-1` when no TLS connection is open
(`third_party/mORMot2/src/net/mormot.net.sock.pas:1213-1219`). `INetTls.Send`
returns `nrRetry` when the socket is not ready, and the caller retries the same
buffer (`...:1220-1225`).

**The per-connection object.** The async server holds one `INetTls` instance
per connection, in the `fSecure` field of `TPollAsyncConnection`
(`third_party/mORMot2/src/net/mormot.net.async.pas:121`, `...:4261`). The
instance is created by `NewNetTls`, which `mormot.lib.openssl11` points at
`NewOpenSslNetTls` once OpenSSL loads
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:12316-12318`).

## The binding

`Http2Server.Alpn` resolves `SSL_CTX_set_alpn_select_cb` from libssl. The
mORMot2 `libssl` handle is a private variable of
`mormot.lib.openssl11` (`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:3153`),
and no public accessor names it, so the unit loads libssl a second time. The
second load uses the same path rules as mORMot2: `OPENSSL_LIBPATH` first, then
the platform library names `LIB_SSL4`, `LIB_SSL3` and `LIB_SSL1`
(`...:143-245`). A second `dlopen` of an already-loaded library returns the
same handle, so no second copy of the library enters the process.

`Http2AlpnBindingAvailable` reports whether the symbol resolved
(`src/Http2Server.Alpn.pas:203-244`). `Http2AlpnAttachCtx` installs the
callback on a server context, and `Http2AlpnAttach` reads that context from a
bound `TCrtSocket` (`src/Http2Server.Alpn.pas:246-262`).

## The select rule

The callback receives the client protocol list in the wire format of RFC 7301:
a vector of 8-bit length-prefixed byte strings. It chooses `h2` wherever that
entry appears. When the caller permits the fallback, it accepts `http/1.1` as
well. When no entry matches, the callback returns
`SSL_TLSEXT_ERR_ALERT_FATAL` (`2`), which refuses the handshake with a fatal
alert. A malformed list — a zero length entry, or an entry that claims more
octets than remain — is refused in the same way.

The decision is a pure function, `Http2AlpnSelectOffset`, which returns the
offset of the chosen entry or `-1` (`src/Http2Server.Alpn.pas:91-136`). The
OpenSSL callback is a thin wrapper over it, so a test reaches every branch of
the rule with no handshake and no socket.

The callback argument is a record with a process lifetime, because the OpenSSL
manual page requires that the argument outlive the handshake
(`src/Http2Server.Alpn.pas:87`).

## The negotiated name

`Http2AlpnSelected` reads the negotiated name with `SSL_get0_alpn_selected`
through the `PSSL` returned by `INetTls.GetRawTls`
(`src/Http2Server.Alpn.pas:185-201`). An empty result means that no protocol
was selected.

## Open verification

The pure select rule and the symbol resolution are verified by the unit tests
of `test/Http2Server.Alpn.Test.pas`, which run in the normal test suite.

Two checks need a live TLS client and are not part of this document's evidence:
the ALPN name that a real handshake reports, and the behaviour of a client that
stalls during the handshake. The scheduler and the output path are the subject
of the later IO-integration work, which performs both checks against the
finished server.

## Sources

| Claim | Source | Read |
|---|---|---|
| The callback signature, the return codes, and the protocol list wire format | OpenSSL manual page `SSL_CTX_set_alpn_select_cb(3ssl)` | 2026-10-07 |
| The `INetTls` surface | `third_party/mORMot2/src/net/mormot.net.sock.pas:1185-1240` | 2026-10-07 |
| The server `SSL_CTX` and its lifetime | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11918-11949` | 2026-10-07 |
| The blocking handshake and its 5000 ms deadline | `...:11953-12009`, `...:12146-12188` | 2026-10-07 |
