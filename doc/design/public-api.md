---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, public-api, factory, handler, observer, statistics
notes:
  - This document describes the public surface of the library.
scope: The public surface of the library — the factory, the server, the handler contract and the observation events.
primary_types:
  - THttp2ServerFactory
  - IHttp2Server
  - THttp2Server
  - IHttp2Handler
  - IHttp2ServerObserver
  - TServerEvent
  - TServerStats
db_tables: []
related_docs:
  - doc/design/configuration.md
  - doc/design/lifecycle.md
  - doc/design/seam.md
  - doc/design/admission.md
invariants:
  - A caller reaches the library through the unit Http2Server alone.
  - The factory is a value. Every WithX method answers a new record, and a stored factory never changes.
  - Build validates the settings and answers a server that is not yet started.
  - The handler contract is synchronous and holds no coroutine.
  - The observer runs on the thread that raised the event.
  - Every counter of TServerStats comes from a live counter of the server, and no number is guessed.
---
# The public API

The unit `src/Http2Server.pas` is the facade. A caller adds that one unit to
the uses clause and sees the whole public surface.

## The factory

`THttp2ServerFactory` (`src/Http2Server.Config.pas`) holds every setting of a
server. The record is immutable: each `WithX` method answers a copy with one
field changed, so a stored factory is safe to reuse and to fork. The defaults
appear once, in `Create` (`src/Http2Server.Config.pas:457-524`).

`Validate` (`src/Http2Server.Config.pas:786`) collects every problem into one
list, so a caller sees all problems in one call.

## Build

`Build` is a type helper for `THttp2ServerFactory`, declared in the facade
(`src/Http2Server.pas:129-135`). `Build` runs `Validate` first. A problem raises
`EServerConfigError` with every problem in one message, one per line. A valid
factory answers an `IHttp2Server` that is not yet started.

`Build` has two forms. `Build` alone answers a server with no observer, and
`Build(AObserver)` answers a server that sends every event to that observer.

## The server

`IHttp2Server` (`src/Http2Server.Server.pas:45-58`) holds five methods:

- `Start` binds the port, starts the IO pool and the handler pool, and
  returns. A second call does nothing. A call after `Stop` raises
  `EServerStopped`, because a stopped server is built again, not started
  again.
- `Stop` sends GOAWAY on every open connection, waits up to the graceful stop
  timeout for the open streams, then stops the pools. A second call does
  nothing.
- `Port` answers the bound port. A factory port of 0 leaves the port to the
  operating system, and `Port` answers the real port after `Start`.
- `Stats` answers the live counters.
- `IsRunning` is true between `Start` and `Stop`.

The implementation is `THttp2Server` (`src/Http2Server.Server.pas:61`), which
owns one `THttp2AsyncServer` (`src/Http2Server.Async.pas:161`).

## The handler

`IHttp2Handler` (`src/Http2Server.Seam.pas:168-172`) holds one method,
`Handle(const ARequest: IServerRequest; const AResponse: IServerResponse)`.
The handler is synchronous: it reads the request, writes the response and
returns. No coroutine and no continuation is part of the contract.

The handler runs on a handler-pool thread. A handler that runs on an IO thread
would hold the connection lock and stall the pool, so the pool checks the rule
at dispatch (`src/Http2Server.Admission.pas:785-787`).

The request carries a read-write `Principal` property. Code that authenticates a
request sets it, and the access log writes it. The factory takes an
`IAccessLogWriter` through `WithAccessLogWriter`; the default is no writer. The
facade also exports `TAccessLogRecord`, `TStdOutAccessLogWriter`,
`FormatCommonLog` and `BasicAuthUser`. [access-log](access-log.md) describes the
record and the format.

The request also carries a read-only `ClientCertificate` property. It answers the
`IClientCertificate` of the TLS client when the listener asks for client
certificates, and nil otherwise. The facade exports `IClientCertificate`,
`TClientCertMode` with the values `ccmNone`, `ccmOptional` and `ccmRequired`, and
`TClientCertPrincipal` with the values `ccpNone`, `ccpSubjectDn` and
`ccpCommonName`. `IServerRequest` has a new GUID because of the two new
properties. The observer receives `seTlsHandshakeFailed` when a handshake fails
while a client certificate mode is on, and `TServerStats.TlsHandshakeFailedTotal`
counts those failures. [mtls](mtls.md) describes the feature.

## Detached streams

`IServerResponse.Detach` ends the synchronous life of a handler and answers an
`IDuplexChannel` (`src/Http2Server.Duplex.pas`). The handler returns, and the
server keeps the stream open. A caller sends from any thread with `Send`, receives
through an `IChannelSink`, and closes the channel with `Close`. The document
[seam](seam.md) describes the channel. The factory settings `StreamPoolSize`,
`MaxDetachedStreams`, `ChannelQueueLimit` and `ChannelLowWater` configure the
part of the server that serves detached streams (see
[configuration](configuration.md)). `Detach` raises `EDetachRefused` when the
server holds `MaxDetachedStreams` channels. The facade `Http2Server` re-exports
`IDuplexChannel`, `IChannelSink`, `TSendResult`, `TChannelClose`,
`TChannelState` and `EDetachRefused`.

## WebSocket

An application serves a WebSocket with an `IWsHandler`. The handler gets an
`IWsSession` and is called on a thread of the streaming pool. `Init` authorises the
upgrade, `Message` gets a whole message, `Pong` and `Closed` report the rest, and
`Failed` reports a callback that raised. `WithWebSockets` sets the limits, the
timers, the origin policy and the subprotocols (`TWsOptions`). The facade
`Http2Server` re-exports `TWsOptions`, `TWsOriginPolicy`, `IWsSession`,
`IWsHandler`, `TWsInitResult`, the origin policies, the close codes that a server
sends and the observer events `seWsOpened`, `seWsRejected`, `seWsClosed`,
`seWsFailed` and `seWsBucketTripped`. The statistics hold the open sessions and the
message and octet counts. `AcceptWebSocket(ARequest, AResponse, AHandler)` upgrades a
request to a WebSocket inside a handler. The document [websocket](websocket.md) describes the
contract.

## HTTP/1.1

The same handler serves HTTP/1.1. `WithHttp11Fallback` turns the fallback on or
off, and `WithHttp11Limits` sets the limits of the parser. `IServerRequest` and
`IServerResponse` have the same meaning on both protocols, and `Detach` works on
both. The document [http1](http1.md) lists what a handler can see.

## Server-sent events

`StartSse` answers a request with an event stream and detaches it. It returns an
`ISseStream`, and any thread sends `TSseEvent` values to it. `SseKeepAliveMs`
and `SseStallTimeoutMs` configure the keep-alive comment and the stall rule. The
document [sse](sse.md) describes the format rules, the threads and the close
rules. The facade `Http2Server` re-exports `ISseStream`, `TSseEvent`,
`ESseError` and `StartSse`.

## The observation events

`IHttp2ServerObserver` (`src/Http2Server.Observer.pas:94-97`) holds one
method, `OnEvent(const AEvent: TServerEvent)`. The server raises one event per
state change that a caller acts on. `TServerEventKind`
(`src/Http2Server.Observer.pas:34-68`) names eighteen kinds. The table lists the
thirteen kinds of the HTTP/2 core. The five WebSocket kinds are named in the
section "WebSocket":

| Kind | Raised when |
| --- | --- |
| `seConnectionAccepted` | a socket is accepted |
| `seConnectionClosed` | a connection ends |
| `seStreamOpened` | a request header block ends |
| `seStreamRefused` | the queue was full or the stream limit was reached |
| `seStreamReset` | the peer, or the server, reset a stream |
| `seStreamCompleted` | a handler returned |
| `seQueueFull` | an offer to the queue was refused |
| `seRequestTimedOut` | a queued request passed its wait limit |
| `seBucketTripped` | a token bucket tripped |
| `seGoAwaySent` | the core sent GOAWAY |
| `seHandlerException` | a handler raised |
| `seStreamDetached` | a handler detached its stream into a channel |
| `seStreamDetachRefused` | a detach was refused because the limit of detached streams was reached |

`OnEvent` runs on the thread that raised the event. That thread is an IO
thread, a handler-pool thread, or the caller of `Start` and `Stop`. A slow
`OnEvent` slows that thread, and on an IO thread it can delay the wake-up of a
connection. An observer that blocks belongs on its own queue.

`TNullServerObserver` (`src/Http2Server.Observer.pas:100`) discards every event.
A server with no observer carries no observation cost.

The connection events come from `THttp2ConnectionEvents`
(`src/Http2Server.Async.Events.pas:45-59`), and the queue events come from
`THandlerPool` (`src/Http2Server.Admission.pas:155`).

## The statistics

`TServerStats` (`src/Http2Server.Observer.pas:109`) holds five gauges and four
totals for the HTTP/2 core. It also holds the WebSocket counters `WsSessions`
(a gauge), `WsMessagesIn`, `WsMessagesOut`, `WsBytesIn`, `WsBytesOut`,
`WsProtocolErrors` and `WsPingTimeouts` (totals).

The gauges count what the server holds now: `BusyHandlers`, `QueueLength`,
`OpenConnections`, `OpenStreams` and `DetachedStreams`. The totals count every event since the
build and never decrease: `RefusedTotal`, `TimedOutTotal`, `ResetTotal` and
`TrippedTotal`.

`THttp2Server.Stats` (`src/Http2Server.Server.pas:168`) reads the handler-pool
counters, the connection counter of the async server, and the stream, reset
and trip totals.
