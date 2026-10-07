{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, tls, alpn, openssl
notes:
  - The TLS route and the ALPN binding of the server.
  - The route is option A: the mORMot2 INetTls interface plus one ALPN
    select callback, installed on the server context after the socket binds.
scope: How the server reaches ALPN, the TLS plug-in of a connection, and the mORMot2 TLS facts the route rests on.
primary_types:
  - TAlpnSelectCb
  - TSslCtxSetAlpnSelectCb
  - TTransport
  - TTlsPolicy
db_tables: None.
related_docs:
  - doc/design/protocol.md
  - doc/design/fpc-runtime.md
  - doc/design/io-pool.md
invariants:
  - A client that offers no acceptable ALPN protocol is refused with a
    fatal alert, so no HTTP/1.1 request ever reaches an HTTP/2 code path.
  - The ALPN callback argument outlives every handshake.
  - A TLS connection that did not negotiate h2 is refused after the handshake.
  - The handshake deadline of the factory never exceeds the mORMot2 bound.
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

## The TLS plug-in of a connection

The unit `src/Http2Server.Tls.pas` applies the policy to a bound socket. It
keeps every decision in a pure function, so a test reaches each branch with no
socket and no OpenSSL.

| Function | Decision |
| --- | --- |
| `TransportFor` | Which transport a policy offers: TLS, cleartext or a refusal (`src/Http2Server.Tls.pas:110-119`). |
| `HandshakeExpired` | Whether a handshake has used up a deadline; a zero deadline never expires (`src/Http2Server.Tls.pas:120-126`). |
| `EffectiveHandshakeTimeoutMs` | The deadline the server applies, clamped to the mORMot2 bound (`src/Http2Server.Tls.pas:128-139`). |
| `NegotiatedH2` and `NegotiatedAlpnName` | Whether the finished handshake selected `h2`; a nil TLS instance answers False (`src/Http2Server.Tls.pas:141-152`). |

`ApplyTls` carries out the policy on a bound socket
(`src/Http2Server.Tls.pas:154-174`). The order is fixed: mORMot2 creates the
server `SSL_CTX` inside `AfterBind`, so the server records the certificate and
the key, calls `DoTlsAfter(cstaBind)`, and only then installs the ALPN
callback on the context that `AfterBind` stored in `AcceptCert`. The call
answers False when no certificate is named or the certificate file is absent.

## The handshake deadline

mORMot2 runs the server handshake at the first read of each connection, inside
`INetTls.AfterAccept`, and it bounds the `SSL_accept` loop with a 5000 ms
deadline (`mormot.lib.openssl11.pas:12146-12166`). A larger factory value can
never take effect, so `EffectiveHandshakeTimeoutMs` clamps the factory value to
that bound (`src/Http2Server.Tls.pas:128-139`). The server also sets the socket
send and receive deadlines to the clamped value before the handshake runs
(`src/Http2Server.Async.pas:262-279`). A client that opens a socket and sends
nothing holds one IO thread for a bounded time only, and other clients still
complete their handshakes on other threads.

A TLS connection must select `h2`. After the handshake the connection checks
the negotiated name and refuses the connection when the name is not `h2`
(`src/Http2Server.Async.pas:262-279`).

## Open verification

The pure select rule and the symbol resolution are verified by the unit tests
of `test/Http2Server.Alpn.Test.pas`, which run in the normal test suite. The
pure TLS decisions and the h2c loopback are verified by
`test/Http2Server.Async.Test.pas`.

**Open gap.** A live TLS handshake loopback is not yet part of the suite. It
needs a self-signed certificate, generated at test time, and a client that
offers the `h2` ALPN name. The ALPN select rule, the negotiated-name check and
the handshake deadline each carry unit tests, and the h2c loopback proves the
IO pool end to end, but no test yet drives `h2` through a real OpenSSL
handshake on this server. The platform run on Linux amd64 is also open, because
this host is macOS aarch64.

## Sources

| Claim | Source | Read |
|---|---|---|
| The callback signature, the return codes, and the protocol list wire format | OpenSSL manual page `SSL_CTX_set_alpn_select_cb(3ssl)` | 2026-10-07 |
| The `INetTls` surface | `third_party/mORMot2/src/net/mormot.net.sock.pas:1185-1240` | 2026-10-07 |
| The server `SSL_CTX` and its lifetime | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11918-11949` | 2026-10-07 |
| The blocking handshake and its 5000 ms deadline | `...:11953-12009`, `...:12146-12188` | 2026-10-07 |
