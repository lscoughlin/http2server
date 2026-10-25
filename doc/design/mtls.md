---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: mtls, client certificate, tls, principal, websocket, http2
notes:
  - The design of mutual TLS. The server asks a client for a certificate,
    verifies it against a configured CA, and gives the identity to the handler.
  - The identity reaches every request path. The paths are HTTP/2 streams,
    HTTP/1.1 requests, the HTTP/1.1 WebSocket upgrade and the HTTP/2 WebSocket
    handshake (extended CONNECT).
  - The feature is built. The live validation drives every mode against the
    sibling client at ../http2client.
scope: The factory settings for client certificates, the verification mode, the identity record, the way the identity reaches a handler, and the HTTP/2 and WebSocket rules.
primary_types:
  - TClientCertMode
  - TClientCertPrincipal
  - TClientCertificateData
  - IClientCertificate
  - IClientCertificateSink
  - TClientTrust
  - TTlsServerOptions
  - TTlsPolicy
db_tables: None.
related_docs:
  - doc/design/tls.md
  - doc/design/configuration.md
  - doc/design/seam.md
  - doc/design/websocket.md
  - doc/design/access-log.md
  - doc/design/http1.md
invariants:
  - A connection that fails client verification never reaches an HTTP/1.1 or an
    HTTP/2 code path. OpenSSL ends the handshake with a fatal alert.
  - The identity belongs to the connection and never changes after the
    handshake. All streams of one HTTP/2 connection report the same identity.
  - The identity comes from a per-connection read of the SSL object. It never
    comes from the shared TNetTlsContext record.
  - The server never copies the certificate into a request header.
  - A handler cannot replace the identity. A handler can replace the principal
    text only through the existing principal setter.
  - The server never sends a TLS 1.3 post-handshake CertificateRequest and
    disables TLS renegotiation.
---
# Mutual TLS

Mutual TLS (mTLS) lets the server ask a client for an X.509 certificate during
the TLS handshake. The server verifies the certificate chain against a CA set
that the caller names. A handler then reads the verified identity from the
request. This document describes the design. The route to ALPN is in
[tls](tls.md).

## Scope

The feature covers every transport that the server offers over TLS:

| Path | How the identity reaches the handler |
| --- | --- |
| HTTP/2 request | The connection holds the identity. Each stream request reads it from the connection. |
| HTTP/1.1 request | The connection holds the identity. The exchange reads it from the connection. |
| WebSocket over HTTP/1.1 (RFC 6455 upgrade) | The upgrade is a normal HTTP/1.1 request. The handler sees the identity in `Handle`, and the session snapshot keeps it. |
| WebSocket over HTTP/2 (RFC 8441 extended CONNECT) | The CONNECT stream is a normal HTTP/2 stream. The handler sees the identity in `Handle`, and the session snapshot keeps it. |
| Cleartext h2c | No TLS, so no identity. The identity is nil. |

The WebSocket handshake over HTTP/2 already exists
([websocket](websocket.md)). The mTLS design adds no new WebSocket frame, no new
setting and no new handshake step. The WebSocket session outlives the handler
call, so the session snapshot copies the identity reference. The copy keeps the
identity after the stream request is gone.

## The settings

`TTlsServerOptions` gains six settings. The defaults keep today's behaviour:
no client certificate is requested.

| Setting | Type | Default | Meaning |
| --- | --- | --- | --- |
| `ClientCertMode` | `TClientCertMode` | `ccmNone` | `ccmNone` asks for no certificate. `ccmOptional` asks and accepts a client that sends none. `ccmRequired` refuses a client that sends none. |
| `ClientCaFile` | `string` | empty | The PEM file with the trust anchors for client certificates. A self-signed client certificate is its own trust anchor, so the file can hold the client certificates directly. |
| `ClientTrustSystemStore` | `Boolean` | False | When True, the certificates of the operating system trust store are trust anchors as well. The system store and the CA file add to each other. |
| `ClientPartialChain` | `Boolean` | False | When True, a trust anchor that is an intermediate or a leaf certificate is enough, with no path to a root (`X509_V_FLAG_PARTIAL_CHAIN`). |
| `ClientVerifyDepth` | `Integer` | 4 | The longest accepted chain between the client certificate and a trusted CA. |
| `ClientCertPrincipal` | `TClientCertPrincipal` | `ccpNone` | What the server writes to `Principal` for a verified client: nothing, the subject DN, or the common name. |

Builder names follow the existing style: `WithClientCertMode`,
`WithClientCaFile`, `WithClientTrustSystemStore`, `WithClientPartialChain`,
`WithClientVerifyDepth` and `WithClientCertPrincipal`.

### Validation

`Problems` reports these errors:

- `ClientCertMode` is not `ccmNone`, `ClientCaFile` is empty and
  `ClientTrustSystemStore` is False. The server then has no trust anchor.
- `ClientCaFile` is not empty and names a file that is not present.
- `ClientVerifyDepth` is below 1 or above 16.
- `ClientCertMode` is `ccmRequired` and cleartext is allowed. A cleartext
  connection cannot present a certificate, so the combination refuses nothing
  it appears to refuse. `ccmOptional` with cleartext is valid. A cleartext
  connection then has a nil identity.
- `ClientCertMode` is not `ccmNone` and no certificate file is set.

## The verification modes

Both modes use OpenSSL verification. OpenSSL ends the handshake with a fatal
alert when a presented certificate fails verification. The handshake failure
happens before the first application byte, so no request code runs.

| Mode | OpenSSL verify mode | Client sends no certificate | Client sends an invalid certificate |
| --- | --- | --- | --- |
| `ccmNone` | `SSL_VERIFY_NONE` | Served, identity nil. | Not requested. |
| `ccmOptional` | `SSL_VERIFY_PEER` | Served, identity nil. | Handshake refused. |
| `ccmRequired` | `SSL_VERIFY_PEER` with `SSL_VERIFY_FAIL_IF_NO_PEER_CERT` | Handshake refused. | Handshake refused. |

### The server applies the trust and the verify mode itself

mORMot2 can do the required mode alone, but it picks one trust source only: the
CA file, or the system stores, or a raw list. `TOpenSslNetTls.SetupCtx` tests
them in an `if` and `else if` chain
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11724-11743`). The design
needs the CA file and the system store together, and it needs the optional mode,
which mORMot2 lacks. Its `ClientCertificateAuthentication` flag always adds
`SSL_VERIFY_FAIL_IF_NO_PEER_CERT`. The server therefore applies both modes
itself after `AfterBind`, in the same hook that installs the ALPN callback
(`ApplyTls` in `src/Http2Server.Tls.pas`). The hook runs these calls on the
`AcceptCert` context, in this order:

1. `SSL_CTX_load_verify_locations` loads `ClientCaFile`, when the file is set.
2. `AddCertificates` on the result of `SSL_CTX_get_cert_store` adds the system
   store, when `ClientTrustSystemStore` is True. The list comes from the mORMot2
   function `LoadCertificatesFromSystemStore`, which caches it.
3. `X509_STORE_set_flags` sets `X509_V_FLAG_PARTIAL_CHAIN`, when
   `ClientPartialChain` is True.
4. `SSL_load_client_CA_file` and `SSL_CTX_set_client_CA_list` build the list of
   acceptable CA names from the CA file only. The system store is large, so its
   names are not sent in the CertificateRequest. A client then chooses its
   certificate without a CA hint when only the system store is set.
5. `SSL_CTX_set_verify` sets `SSL_VERIFY_PEER` and `SSL_VERIFY_CLIENT_ONCE`,
   plus `SSL_VERIFY_FAIL_IF_NO_PEER_CERT` in the required mode.
6. `SSL_CTX_set_verify_depth` sets `ClientVerifyDepth`.

mORMot2 declares these entry points in `mormot.lib.openssl11`, except
`SSL_CTX_set_verify_depth`, `SSL_CTX_get_verify_depth` and
`SSL_CTX_get_verify_mode`. The unit `src/Http2Server.Tls.Client.pas` resolves those
three from libssl with the path rules of the ALPN binding. A second `dlopen` of an
already loaded library returns the same handle.

The server leaves `ClientCertificateAuthentication` off on the `TNetTlsContext`,
so `SetupCtx` does not set a verify mode of its own that the hook must undo. The
server today sets `IgnoreCertificateErrors` to True for the listener
(`BuildTlsPolicy` in `src/Http2Server.Async.Options.pas`), and that makes `SetupCtx` choose
`SSL_VERIFY_NONE`. The hook overrides the mode after `AfterBind`. A test reads
the verify mode back with `SSL_CTX_get_verify_mode` for each of the three modes,
so a later mORMot2 change cannot weaken the setting without a test failure.

### Self-signed client certificates

A self-signed certificate is its own trust anchor. It verifies when it sits in
`ClientCaFile`. The operating system store holds public and enterprise roots, and
it does not hold a private self-signed certificate unless an operator installs
it there. A deployment with self-signed client certificates therefore lists
them in `ClientCaFile`, or installs them in the system store and sets
`ClientTrustSystemStore`. A self-signed certificate that is not a CA (it lacks
the basic constraints extension with the CA flag) verifies as a leaf trust
anchor in OpenSSL only when it is in the store. `ClientPartialChain` makes a
leaf or an intermediate in the store enough for a chain that does not end in a
root.

### Trust of the system store

The system store trusts every public CA. With `ClientTrustSystemStore` on, any
holder of a certificate from a public CA passes the TLS verification, and the
verification says nothing about who the holder is. The handler must check the
identity: the issuer, a SAN, or the fingerprint. The principal setting
`ccpNone` is the default for this reason. The documentation of the setting
states the risk. A deployment that wants only its own clients leaves the system
store off and uses `ClientCaFile`.

## Disabled TLS features

HTTP/2 over TLS 1.2 must disable renegotiation, and a server must not send a
post-handshake CertificateRequest on TLS 1.3 (RFC 9113 sections 9.2.1 and 9.2.3,
read from `doc/references/rfc9113.txt`). The server meets both rules:

- The client certificate is requested in the first handshake only. The server
  never calls `SSL_verify_client_post_handshake`.
- `ApplyTls` sets `SSL_OP_NO_RENEGOTIATION` on the context when
  `ClientCertMode` is not `ccmNone`.
- A deployment that needs a certificate for some paths only uses
  `ccmOptional` and checks the identity in the handler. The server offers no
  per-path renegotiation.

## The identity

### The record

`TClientCertificateData` is an immutable record of text values. The server fills it
once, after the handshake, from the SSL object of the connection.

| Field | Content |
| --- | --- |
| `SubjectDn` | The subject distinguished name as text. |
| `IssuerDn` | The issuer distinguished name as text. |
| `CommonName` | The first common name of the subject, or empty. |
| `SerialHex` | The serial number in upper-case hexadecimal. |
| `Sha256` | The SHA-256 fingerprint of the DER certificate, in lower-case hexadecimal. |
| `SanDns` | The DNS names of the subject alternative name extension. |
| `SanUri` | The URI names of the subject alternative name extension. |
| `SanEmail` | The e-mail names of the subject alternative name extension. |
| `NotBefore`, `NotAfter` | The validity period, in UTC. |
| `Pem` | The leaf certificate in PEM form. |

The record keeps the leaf certificate only. The subject alternative name lists keep
the DNS, URI and e-mail names. An IP address name is dropped. A handler that needs the chain
reads `Pem` and parses it.

The DN text comes from the mORMot2 `SubjectName` and `IssuerName`. It lists the
RDNs from the last element of the RDN sequence to the first, as RFC 4514
section 2.1 requires. A certificate whose sequence reads `CN`, `O`, `OU` gives
`OU=Eng,O=Example,CN=alice`. The live
validation checks this text. The escaping of special characters in a value is
not verified, so a handler that compares a DN compares the `Sha256` or a SAN
instead.

### Why a per-connection read

`TOpenSslNetTls.AfterAccept` fills `PeerSubject` and `PeerCert` in a local copy
of the context, and mORMot2 comments that the main context is shared
(`third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11953-11990`). Many
connections run in parallel on one context, so the identity of one connection
never comes from the shared record. The server reads the peer certificate from
the `PSSL` that `INetTls.GetRawTls` returns for that connection, the same way
`NegotiatedAlpnName` reads the ALPN name (`NegotiatedAlpnName` in `src/Http2Server.Tls.pas`).

### Where the read happens

`TAsyncConnection.OnFirstRead` finishes the handshake through `inherited
OnFirstRead` and then checks the ALPN name (`THttp2AsyncConnection.OnFirstRead` in `src/Http2Server.Async.pas`).
The identity read follows the handshake in the same method, before
`StartHttp2` or `StartHttp1`. The connection object then holds the reference.
The connection object keeps the reference. It passes it to the connection-events
object of the protocol (`src/Http2Server.Async.Events.pas`). The HTTP/2 events set
it on each `TServerStream` in `RequestReady`, and the HTTP/1.1 events give it to
the exchange through `IClientCertificateSink`. A stream or an exchange reads it
with no lock, because the value never changes.

A connection object can be reused by mORMot2 ([io-pool](io-pool.md)). The reset
of the connection state clears the identity reference, so a reused object never
shows the identity of the previous client.

## How the handler sees the identity

`IServerRequest` gains one property:

```pascal
function GetClientCertificate: IClientCertificate;
property ClientCertificate: IClientCertificate read GetClientCertificate;
```

`IClientCertificate` is a read-only interface over `TClientCertificateData`. The
property answers nil when the connection is cleartext, when the mode is
`ccmNone`, or when the mode is `ccmOptional` and the client sent no
certificate. A handler tests for nil.

The interface has a new GUID, `{7E1F0C11-0003-4A11-9C72-000000000513}`, because
of the two new properties, `Principal` and `ClientCertificate`.

The three request implementations carry the property:

- `TServerStreamRequest` (`src/Http2Server.StreamAdapters.pas`) for HTTP/2.
- `TH1Exchange` (`src/Http2Server.Http1.Exchange.pas`) for HTTP/1.1.
- `TWsRequestSnapshot` (`src/Http2Server.Ws.SessionCore.pas`) for the session.
  The snapshot constructor copies the reference from the source request, as it
  copies the principal today (`src/Http2Server.Ws.SessionCore.pas:156`).

### The principal

When `ClientCertPrincipal` is not `ccpNone` and the identity is not nil, the
server sets `Principal` before it calls the handler. `ccpSubjectDn` writes the
subject DN. `ccpCommonName` writes the common name. A handler or a
decorator can replace the text later, as the [access log](access-log.md)
describes. The access log then writes the certificate principal in the user
field with no change to the log code.

The principal text is a convenience. A handler that decides on a certificate
reads `ClientCertificate` and checks the fingerprint, a SAN or the issuer. It
does not parse the principal text.

### No header injection

The server never writes the certificate or the DN into a request header. A
header looks the same as a header that a client sent, so a handler could
confuse a forged header with an identity. The handler reads the identity from
the property only.

## Refusals and observation

A refused handshake closes the connection before `OnFirstRead` returns True.
The existing handler for a failed first read ends the connection
(the `except` branch and the failed-handshake branch of `OnFirstRead`). The observer receives a new event kind,
`seTlsHandshakeFailed`, when mTLS is on and the handshake fails. The event
means "a handshake failed while mTLS was on". The server cannot tell a missing
certificate from an invalid certificate, or from a plain TLS error of a
scanner, without the OpenSSL error text. The event therefore carries a fixed text,
or the message of the exception when `OnFirstRead` raises.

## Session resumption

The server keeps TLS session resumption on. mORMot2 sets a session id context on
the server context when it creates it, so OpenSSL accepts a resumed session on a
server that verifies client certificates. A manual check with `openssl s_client`
and a saved session resumed both a TLS 1.2 and a TLS 1.3 session with a client
certificate (2026-10-25). The live validation does not repeat this check.

## Limits of this design

- The server does not check certificate revocation. A CRL or OCSP check is a
  later feature.
- The chain is verified by OpenSSL against the CA file and, when set, the
  system store.
- The CA file and the system store are read when the server starts. A change
  to either needs a restart.
- The record holds the leaf certificate. Intermediate certificates that the
  client sent are not exposed.
- A client certificate does not reach an HTTP/1.1 upgrade that a proxy
  terminated. The server sees the proxy certificate only.

## Verification

The unit tests (`test/Http2Server.Mtls.Test.pas`) cover the pure parts: the
validation rules, the map from a mode to an OpenSSL flag, the principal text,
the identity record of a generated certificate, and the trust setup on a bare
server context. The context test reads the verify mode and the depth back with
`SSL_CTX_get_verify_mode` and `SSL_CTX_get_verify_depth`.

The live validation (`make mtls-live`) starts the server on loopback with a PKI
that `tools/certs/make_mtls_pki.sh` makes, and drives it with the sibling
client at `../http2client`. A raw TLS client built on the TLS socket of that
client covers the cases that the client library lacks: an expired certificate,
HTTP/1.1 over TLS and WebSocket over HTTP/2. The run holds 34 checks:

| Group | Checks |
| --- | --- |
| `ccmNone` | a client without a certificate is served; a certificate that nobody asked for gives no identity; the raw HTTP/2 client is served |
| `ccmOptional` | no certificate gives a nil identity; a valid certificate gives the subject, the issuer, the SAN names and the principal; a certificate of an unknown CA is refused with no handler call; WebSocket over HTTP/2 without a certificate opens and the handler sees nil |
| `ccmRequired` | no certificate, an unknown CA, a self-signed certificate outside the trust and an expired certificate are refused with no handler call, and the observer counts the failed handshakes; a valid certificate is served; two requests on one connection show one identity; HTTP/1.1 over TLS shows the identity; WebSocket over HTTP/2 shows the identity at `Init` and at the first message; WebSocket over HTTP/2 without a certificate is refused; WebSocket over HTTP/1.1 shows the identity |
| Trust | a self-signed client in the CA file is served; the root and the self-signed client are served together; an unknown CA stays refused; with the system store only, a client of a private root is refused |

Open gaps:

- A client of a public CA that the system store trusts is not tested, because
  mORMot2 gives no way to redirect the system store and the run never changes
  the store of the host.
- A native leak of the `X509` reference of the reader is not measured. The heap
  trace run shows no block from the identity code, and the reader frees the
  reference in a `finally` block.
- The run is on macOS aarch64 only. The Linux amd64 run is open, as for the rest
  of the library.
- No load or stress run is part of this feature.

## Sources

| Claim | Source | Read |
| --- | --- | --- |
| Renegotiation is off and post-handshake CertificateRequest is not sent | RFC 9113 sections 9.2.1 and 9.2.3, https://www.rfc-editor.org/info/rfc9113, `doc/references/rfc9113.txt` | 2026-10-25 |
| The extended CONNECT handshake of WebSocket over HTTP/2 | RFC 8441, https://www.rfc-editor.org/info/rfc8441, `doc/references/rfc8441.txt` | 2026-10-25 |
| The mORMot2 mTLS flags and the verify setup | `third_party/mORMot2/src/net/mormot.net.sock.pas:1008-1036`, `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11709-11735` | 2026-10-25 |
| The shared context in `AfterAccept` | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11953-11990` | 2026-10-25 |
