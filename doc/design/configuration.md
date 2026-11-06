---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, config, factory, options, tls, queue
notes:
  - The factory and the option records of the server.
  - Every server setting passes through the factory. Create holds the only
    block of defaults.
scope: The factory record, the option records it carries, and the validation rules.
primary_types:
  - THttp2ServerFactory
  - TTlsServerOptions
  - TTlsVersion
  - TQueueOptions
  - TQueueRefusalMode
  - TServerLimits
  - TSocketOptions
db_tables: None.
related_docs:
  - doc/design/limits.md
  - doc/design/lifecycle.md
  - doc/design/protocol.md
  - doc/design/tls.md
invariants:
  - A WithX call returns a new record and never changes the record it was
    called on.
  - The numeric defaults of the server exist in one place, the body of
    THttp2ServerFactory.Create, and in the Create bodies of the four option
    records.
  - Validate reports every problem in one call.
---
# Configuration

Every setting of the HTTP/2 server passes through one object: the server
factory. The factory is a record with a fluent interface, in the same form as
the client factory of the sibling project. A `WithX` method returns a new
record with one field changed. The record that the method was called on keeps
its value, so a stored factory is safe to copy and to fork.

## The factory record

`THttp2ServerFactory` is a record (`src/Http2Server.Config.pas:97`). Its
fields are private and its properties are read-only, so a caller changes a
setting only through a `WithX` method.

`Create` is a static class function that returns the record with the defaults
(`src/Http2Server.Config.pas:395-465`). The defaults appear once, in that body.
The four option records hold their own defaults in their own `Create` bodies
(`src/Http2Server.Config.Tls.pas:104`, `src/Http2Server.Config.Limits.pas:80`,
`src/Http2Server.Config.Socket.pas:75`, `src/Http2Server.Config.pas:363`). The
figure below shows the five records and their relation.

```mermaid
flowchart TD
    F["THttp2ServerFactory"]
    T["TTlsServerOptions"]
    Q["TQueueOptions"]
    L["TServerLimits"]
    S["TSocketOptions"]
    B["TTokenBucketOptions"]
    F --> T
    F --> Q
    F --> L
    F --> S
    F --> B
```

The factory is the home of every server setting. The protocol units hold the
protocol bounds instead: `MinAllowedFrameSize` and `MaxAllowedFrameSize`
(`src/Http2Server.Frames.pas:42`, `src/Http2Server.Frames.pas:44`), and
`MaxWindowSize` (`src/Http2Server.FlowControl.pas:28`). A connection reads the
remaining values from a settings record that the factory fills, as the
connection core states for `TConnectionCoreOptions`
(`src/Http2Server.Connection.Core.pas:41-78`).

The test `TestDefaultsOnlyInCreate` reads the sources of the factory units
and fails on a numeric literal above 1 outside a `Create` body
(`test/Http2Server.Config.Test.pas:807`). The test covers the four factory
units: `Config`, `Config.Tls`, `Config.Limits` and `Config.Socket`.
`Http2Server.Stream.pas` holds its own constants (`DefaultReadTimeoutMs`,
`DefaultWriteTimeoutMs` and `DefaultUpdateThreshold` in
`src/Http2Server.Stream.pas`), which a stream uses until the factory
sets a value.

### The listener settings

| Setting | `WithX` | Meaning |
|---|---|---|
| `Host` | `WithHost` | the address of the listener, such as `0.0.0.0` or `::1`; the listener binds this address only (`BindAddressText`) |
| `Port` | `WithPort` | the TCP port; 0 asks the operating system for a free port |
| `Backlog` | `WithBacklog` | the length of the listen backlog; the value is set before the bind and held under a lock until the bind has run, so two servers keep their own value |
| `Http11Fallback` | `WithHttp11Fallback` | serves HTTP/1.1 on the same listener when the peer does not speak HTTP/2; on by default |
| `WebSockets` | `WithWebSockets` | the record `TWsOptions`: the limits, the timers, the buckets, the origin policy and the subprotocols of the WebSocket part (see [websocket](websocket.md)) |
| `Http11` | `WithHttp11Limits` | the record `THttp11Limits`: the limits of the HTTP/1.1 parser (see [http1](http1.md)) |
| `ClearTextAllowed` | `WithClearTextAllowed` | allows cleartext connections (HTTP/2 with prior knowledge, and HTTP/1.1 when the fallback is on); off by default |

The listener fields are at `src/Http2Server.Config.pas:99-102` (host, port, backlog, cleartext) and at `src/Http2Server.Config.pas:114-117` (fallback, HTTP/1.1 limits, WebSocket).

### The TLS settings

`TTlsServerOptions` is a record with its own fluent methods
(`TTlsServerOptions` in `src/Http2Server.Config.Tls.pas`). `THttp2ServerFactory.WithTls`
accepts the record whole.

| Setting | `WithX` | Meaning |
|---|---|---|
| `CertificateFile` | `WithCertificateFile` | the path of the PEM certificate file |
| `KeyFile` | `WithKeyFile` | the path of the PEM private key file |
| `KeyPassword` | `WithKeyPassword` | the password of an encrypted key, or an empty string |
| `HandshakeTimeoutMs` | `WithHandshakeTimeoutMs` | the time a handshake may take |
| `MinTlsVersion` | `WithMinTlsVersion` | the lowest TLS version that the listener accepts |
| `MaxTlsVersion` | `WithMaxTlsVersion` | the highest TLS version that the listener accepts |

`TTlsVersion` has two values (`src/Http2Server.Config.Tls.pas:29`). The value
`tvTls12` is TLS 1.2 and the default minimum. The value `tvTls13` is TLS 1.3
and the default maximum. No value below TLS 1.2 exists by design, because
HTTP/2 forbids older versions (RFC 9113, section 9.2, checked 2026-11-06 at
https://www.rfc-editor.org/info/rfc9113; the plain-text copy is
doc/references/rfc9113.txt).

The client certificate settings follow in the same record. They default to no
client certificate. [mtls](mtls.md) describes them.

| Setting | `WithX` | Default | Meaning |
|---|---|---|---|
| `ClientCertMode` | `WithClientCertMode` | `ccmNone` | whether the server asks for a client certificate: `ccmNone`, `ccmOptional` or `ccmRequired` |
| `ClientCaFile` | `WithClientCaFile` | empty | the PEM file with the trust anchors for client certificates |
| `ClientTrustSystemStore` | `WithClientTrustSystemStore` | False | the operating system store adds trust anchors |
| `ClientPartialChain` | `WithClientPartialChain` | False | a leaf or intermediate trust anchor is enough |
| `ClientVerifyDepth` | `WithClientVerifyDepth` | 4 | the longest accepted chain, 1 to 16 |
| `ClientCertPrincipal` | `WithClientCertPrincipal` | `ccpNone` | what the server writes to `Principal` for a verified client |

The ALPN protocols are not a setting. The server offers `h2`, and it adds
`http/1.1` when `Http11Fallback` is on. [tls](tls.md) describes how the ALPN name
reaches OpenSSL.

### The pool settings

| Setting | `WithX` | Meaning |
|---|---|---|
| `IOThreads` | `WithIOThreads` | the number of IO pool threads |
| `HandlerThreads` | `WithHandlerThreads` | the number of handler pool threads |
| `StreamPoolSize` | `WithStreamPoolSize` | the number of threads of the streaming pool, which runs the application work for detached streams; the default is 1 |
| `MaxDetachedStreams` | `WithMaxDetachedStreams` | the greatest number of detached streams of the whole server; 0 refuses every detach; the default is 10000 |
| `ChannelQueueLimit` | `WithChannelQueueLimit` | the outbound queue limit of a detached stream, in bytes; the default is 262144 |
| `ChannelLowWater` | `WithChannelLowWater` | the queued byte count at or below which a refused writer is told that the queue drained; the default is 65536 |
| `MaxOutputQueueBytes` | `WithMaxOutputQueueBytes` | the most octets that the output queue of one connection may hold, counted with the octets that wait in the socket write buffer; a peer that does not read ends the connection with `ENHANCE_YOUR_CALM` above it; 0 sets no cap; the default is 16777216 |
| `SseKeepAliveMs` | `WithSseKeepAlive` | the period of the keep-alive comment of an event stream, in milliseconds; 0 turns it off; the default is 15000 |
| `SseStallTimeoutMs` | `WithSseStallTimeout` | the time that a full event stream may stay full before the server closes it, in milliseconds; 0 turns the check off; the default is 30000 |

A cancel hook runs at most once, never on the thread that called `Cancel`
(`src/Http2Server.Seam.pas:64-70`). The count of cancel workers decides how many
hooks run at the same time.

### The queue settings

`TQueueOptions` is a record with its own fluent methods
(`src/Http2Server.Config.pas:71`). `THttp2ServerFactory.WithQueue` accepts the
record whole (`src/Http2Server.Config.pas:565`).

| Setting | `WithX` | Meaning |
|---|---|---|
| `Depth` | `WithDepth` | the greatest number of requests that wait for a handler |
| `MaxWaitMs` | `WithMaxWaitMs` | the greatest wait of a queued request |
| `RefusalMode` | `WithRefusalMode` | the action when the queue is full |

`TQueueRefusalMode` has two values (`src/Http2Server.Config.pas:57-61`). The
value `rmRefuseStream` resets the stream with `REFUSED_STREAM`. The value
`rmHttp503` answers HTTP 503. The two answers differ in the retry rule. RFC
9113 §5.1.2 states that the error code decides whether automatic retry is
enabled (RFC 9113, section 5.1.2, read 2026-10-07).

A depth of 0 is legal. With depth 0 no request waits, so every request beyond
the free handlers is refused at once.

### The server limits

`TServerLimits` is a record with its own fluent methods
(`src/Http2Server.Config.Limits.pas:33`). `THttp2ServerFactory.WithServerLimits`
accepts the record whole (`src/Http2Server.Config.pas:579`).

| Setting | `WithX` | Meaning |
|---|---|---|
| `MaxConnections` | `WithMaxConnections` | the greatest number of open connections; the default is 10000; 0 means no cap |
| `StreamReadTimeoutMs` | `WithStreamReadTimeoutMs` | the greatest wait for a read of a stream, in milliseconds; the default is 30000 |
| `StreamWriteTimeoutMs` | `WithStreamWriteTimeoutMs` | the greatest wait for a write of a stream, in milliseconds; the default is 30000 |
| `WriteTimeoutMs` | `WithWriteTimeoutMs` | the greatest wait for a write of a connection, in milliseconds; 0 turns the check off; the default is 60000 |
| `MaxOutboundFrames` | `WithMaxOutboundFrames` | the greatest number of outbound frames that wait for the peer; 0 turns the cap off; the default is 10000 |
| `MaxOutboundControlFrames` | `WithMaxOutboundControlFrames` | the greatest number of outbound control frames that wait for the peer; the default is 1000 |
| `MaxDataFrameSizeOut` | `WithMaxDataFrameSizeOut` | the greatest size of an outbound DATA frame, in octets: 0, or 1024 to 16777215; 0 (the default) sends up to `MaxFrameSize` |

A `MaxConnections` value of N allows exactly N open connections. The
mORMot2 test runs before the new socket joins the set and is strict, so the
server maps N to N minus one. A value of 0 means no cap.

The default 60000 of `WriteTimeoutMs` replaces the link of the HTTP/1.1
`WriteStallMs` to `IdleTimeoutMs`. The write timeout is now a setting of its
own.

`MaxFrameSize` has two roles: the `SETTINGS_MAX_FRAME_SIZE` that the server
accepts, and the bound of the size that the server sends. `MaxDataFrameSizeOut`
sets a separate bound for outbound DATA frames. The value 0 keeps the
`MaxFrameSize` bound.

### The socket options

`TSocketOptions` is a record with its own fluent methods
(`src/Http2Server.Config.Socket.pas:29`). `THttp2ServerFactory.WithSocketOptions`
accepts the record whole (`src/Http2Server.Config.pas:582`).

| Setting | `WithX` | Meaning |
|---|---|---|
| `TcpNoDelay` | `WithTcpNoDelay` | sends a small packet at once, without the delay of Nagle; on by default |
| `KeepAliveIdleSec` | `WithKeepAliveIdleSec` | the idle time before the first keep-alive probe, in seconds; 0 (the default) turns keep-alive off |
| `KeepAliveIntervalSec` | `WithKeepAliveIntervalSec` | the time between two keep-alive probes, in seconds; the default is 0 |
| `KeepAliveCount` | `WithKeepAliveCount` | the number of failed probes before the peer is declared dead; the default is 0 |
| `SendBufferBytes` | `WithSendBufferBytes` | the size of the send buffer, in bytes; 0 (the default) keeps the operating system default |
| `RecvBufferBytes` | `WithRecvBufferBytes` | the size of the receive buffer, in bytes; 0 (the default) keeps the operating system default |
| `ReusePort` | `WithReusePort` | lets more than one listener bind the same port; off by default |

When the idle value is above 0, the interval and the count are above 0 too.
An idle value of 0 turns keep-alive off, and the interval and the count are
then unused.

### The stream settings

| Setting | `WithX` | Meaning |
|---|---|---|
| `MaxConcurrentStreams` | `WithMaxConcurrentStreams` | `SETTINGS_MAX_CONCURRENT_STREAMS` of one connection |
| `InitialStreamWindow` | `WithInitialStreamWindow` | `SETTINGS_INITIAL_WINDOW_SIZE` of every new stream |
| `InitialConnectionWindow` | `WithInitialConnectionWindow` | the initial flow-control window of the connection |
| `MaxFrameSize` | `WithMaxFrameSize` | `SETTINGS_MAX_FRAME_SIZE` that the server accepts |
| `MaxHeaderListSize` | `WithMaxHeaderListSize` | `SETTINGS_MAX_HEADER_LIST_SIZE` that the server accepts |
| `MaxContinuationFrames` | `WithMaxContinuationFrames` | the greatest count of `CONTINUATION` frames in one header block |
| `HeaderTableSize` | `WithHeaderTableSize` | `SETTINGS_HEADER_TABLE_SIZE` of the HPACK codecs |

The stream settings are declared at `src/Http2Server.Config.pas:119-125`. The
protocol limits come from the protocol units, not from the factory:
`MinAllowedFrameSize` and `MaxAllowedFrameSize`
(`src/Http2Server.Frames.pas:42`, `src/Http2Server.Frames.pas:44`), and
`MaxWindowSize` (`src/Http2Server.FlowControl.pas:28`). A connection uses the
settings in `TConnectionSettings` (`src/Http2Server.Frames.pas:94`).

### The bucket limits

The factory holds one `TTokenBucketOptions` per limited client action: the
reset bucket and one bucket per control frame kind
(`src/Http2Server.Config.pas:126-131`). Each bucket has its own `WithX`
method (`src/Http2Server.Config.pas:649-689`). `TTokenBucketOptions` is the
fluent record of `src/Http2Server.Limits.pas:71`; [limits](limits.md)
describes the bucket itself.

| Bucket | `WithX` | The client action it bounds |
|---|---|---|
| reset | `WithResetBucket` | `RST_STREAM`, the rapid-reset technique of CVE-2023-44487 |
| ping | `WithPingBucket` | `PING` |
| settings | `WithSettingsBucket` | `SETTINGS` |
| empty data | `WithEmptyDataBucket` | `DATA` with no payload |
| window update | `WithWindowUpdateBucket` | `WINDOW_UPDATE`, the tiny-increment technique of RFC 9113 section 10.5 |
| continuation | `WithContinuationBucket` | `CONTINUATION`, the flooding technique of CERT VU#421644 |

The reset bucket has two costs. `CostBeforeDispatch` applies to a reset before
a handler runs, and `CostAfterDispatch` applies to a reset after a handler
runs (`src/Http2Server.Limits.pas:376-381`). The other buckets take their cost
from the caller of `TryTake`.

### The timeout settings

| Setting | `WithX` | Meaning |
|---|---|---|
| `IdleTimeoutMs` | `WithIdleTimeout` | the time an idle connection stays open |
| `HeaderTimeoutMs` | `WithHeaderTimeout` | the time the header block of a request may take |
| `GracefulStopTimeoutMs` | `WithGracefulStopTimeout` | the time a graceful stop waits for the open streams |

The timeout settings are declared at `src/Http2Server.Config.pas:132-134`.

### The connection lifetime settings

| Setting | `WithX` | Meaning |
|---|---|---|
| `MaxConnectionAgeMs` | `WithMaxConnectionAge` | the time from accept after which the server retires the connection; 0 (the default) turns the limit off |
| `MaxStreamsPerConnection` | `WithMaxStreamsPerConnection` | the number of requests one connection serves before the server retires it; 0 (the default) turns the limit off |

The lifetime fields are at `src/Http2Server.Config.pas:135-136`. Both defaults are 0, set in `Create` (`src/Http2Server.Config.pas:460-461`). `Validate` rejects a negative value of either one (`src/Http2Server.Config.pas:852-855`). [lifecycle](lifecycle.md) describes the retire.

### The wiring

| Setting | `WithX` | Meaning |
|---|---|---|
| `Handler` | `WithHandler` | the handler that serves every request; required |
| `AccessLogWriter` | `WithAccessLogWriter` | the receiver of the access log records; nil (the default) writes no log, see [access-log](access-log.md) |
| `Clock` | `WithClock` | the clock of the token buckets and of the timeouts |

The wiring is declared at `src/Http2Server.Config.pas:137-139`. `IHttp2Handler`
is the handler contract (`src/Http2Server.Seam.pas:168-172`). `IMonotonicClock` is the
clock interface, and `TMonotonicClock` is its real implementation
(`src/Http2Server.Limits.pas:40`, `src/Http2Server.Limits.pas:47`). `Create`
builds the default clock, so a caller sets no clock for a normal server.

## Validation

`Validate(out AProblems: TArray<string>): Boolean` collects every problem of
the settings into one list (`src/Http2Server.Config.pas:746`). The answer is
`True` and the list is empty when every setting is correct. The answer is
`False` and the list holds one message per problem when a setting is wrong.
The method does not stop at the first problem.

The rules are:

| Rule | Problem message |
|---|---|
| the port is 0 to 65535 | the port is outside the range |
| the backlog is at least 1 | the listen backlog is below 1 |
| the IO thread count is at least 1 | the IO thread count is below 1 |
| the handler thread count is at least 1 | the handler thread count is below 1 |
| the queue depth is at least 0 | the queue depth is below 0 |
| the maximum queue wait is at least 0 | the maximum queue wait is below 0 |
| the connection count is at least 0 | the maximum connection count is below 0 |
| the stream read timeout is at least 1 | the stream read timeout is below 1 |
| the stream write timeout is at least 1 | the stream write timeout is below 1 |
| the write timeout is at least 0; 0 turns the check off | the write timeout is below 0 |
| the outbound frame cap is at least 0; 0 turns the cap off | the outbound frame cap is below 0 |
| the outbound control frame cap is at least 0 | the outbound control frame cap is below 0 |
| the control frame cap is not above the frame cap when both are above 0 | the control frame cap is above the frame cap |
| the outbound data frame size is 0, or 1024 to 16777215 | the outbound data frame size is outside the range |
| the keep-alive values are at least 0, and all three are above 0 when the idle value is above 0 | the keep-alive values are not valid |
| the buffer sizes are at least 0 | the socket buffer size is below 0 |
| the minimum TLS version is not above the maximum | the minimum TLS version is above the maximum |
| the certificate file is present when cleartext is off | the certificate file is empty |
| a client certificate mode has a trust anchor | the mode is not `ccmNone`, the CA file is empty and the system store is off |
| the client CA file exists | the CA file is named and absent |
| the client verify depth is 1 to 16 | the depth is outside the range |
| a client certificate mode has a server certificate | the mode is not `ccmNone` and the certificate file is empty |
| the required mode runs with cleartext off | the mode is `ccmRequired` and cleartext is allowed |
| the frame size is 16384 to 16777215 | the frame size is outside the range |
| the initial stream window is at most 2^31-1 | the stream window is above the limit |
| the initial connection window is at most 2^31-1 | the connection window is above the limit |
| the initial stream window and the initial connection window are at least 1 | the window is below 1 |
| the concurrent stream limit is at least 1 | the concurrent stream limit is below 1 |
| the header table size is at most 2^31-1 | the header table size is above the limit |
| each of the six control buckets has a capacity of at least 1 and a refill rate of at least 0 | the bucket capacity is below 1, or the refill rate is below 0 |
| the idle, header and graceful stop timeouts are at least 0 | the timeout is below 0 |
| the maximum connection age is at least 0 | the maximum connection age is below 0 |
| the stream cap is at least 0 | the maximum streams per connection is below 0 |
| the handler is assigned | the handler is not assigned |

Port 0 is legal, and it asks the operating system for a free port. A queue depth
of 0 is legal too: it refuses every request that finds no free handler. The key
file is optional, because a PEM certificate file can hold the key (the TLS layer
accepts an empty key file). The certificate and the key are not required when `ClearTextAllowed` is set, as
`TestValidateCleartextNeedsNoCertificate` shows
(`test/Http2Server.Config.Test.pas:435`).

A caller that builds a server raises `EServerConfigError` when `Validate`
answers `False` (`src/Http2Server.Errors.pas:79`). The message holds the whole
problem list, so one exception names every problem.

## Default values

The defaults of the buckets, the queue depth and the IO thread count come
from the load runs, and [limits](limits.md) names the measurement of each
one. The remaining values are the chosen protocol and operational bounds.
The values are:

| Group | Defaults |
|---|---|
| Listener | host `0.0.0.0`, port 8443, backlog 128, cleartext off |
| TLS | no certificate, no key, no password, ALPN `h2`, handshake timeout 10000 ms, TLS 1.2 to TLS 1.3, no client certificate (`ccmNone`), verify depth 4, principal `ccpNone` |
| Pools | 4 IO threads, 8 handler threads, 2 cancel workers |
| Queue | depth 64, maximum wait 5000 ms, refusal by `REFUSED_STREAM` |
| Server limits | 10000 connections, stream timeouts 30000 ms, write timeout 60000 ms, outbound caps 10000 frames and 1000 control frames, no separate DATA cap |
| Socket | TCP no-delay on, keep-alive off, operating system buffer sizes, reuse-port off |
| Streams | 100 concurrent streams, 65535 stream window, 65535 connection window, 16384 frame size, 65536 header list size, 16 `CONTINUATION` frames, 4096 header table |
| Buckets | reset bucket 1000 tokens with a refill of 100 per second and costs 1 and 5; `PING`, `SETTINGS`, `empty DATA` and `CONTINUATION` 100 tokens with a refill of 10 per second; `WINDOW_UPDATE` 10000 tokens with a refill of 4000 per second |
| Timeouts | idle 60000 ms, header 30000 ms, graceful stop 10000 ms, maximum age off, maximum streams per connection off |
| Wiring | no handler, the process monotonic clock |

## What the factory does not hold

The factory holds no `Build` method. The helper `THttp2ServerFactoryHelper`
in `src/Http2Server.pas` adds `Build`, which reads the settings of the factory
and returns an `IHttp2Server`.

The factory holds no observer. A caller passes an `IHttp2ServerObserver` to
`Build`, or passes none.

## Verification

The unit tests are in `test/Http2Server.Config.Test.pas` and
`test/Http2Server.MoreConfig.Test.pas` and run in the normal suite. They cover
the defaults, the immutability rule of every `WithX`, the validation rules one
by one, a validation call that reports several problems, and the source rule
that keeps a numeric default inside a `Create` body.

Two behaviours need a running server and are not part of this document's
evidence: the bound port, and the refusal action of a full queue. The server
lifecycle and admission work covers both against the finished server.
