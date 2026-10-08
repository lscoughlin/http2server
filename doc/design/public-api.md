{**
---
license: TBD-LICENCE
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
appear once, in `Create` (`src/Http2Server.Config.pas:396-437`).

`Validate` (`src/Http2Server.Config.pas:628`) collects every problem into one
list, so a caller sees all problems in one call.

## Build

`Build` is a type helper for `THttp2ServerFactory`, declared in the facade
(`src/Http2Server.pas:84-89`). `Build` runs `Validate` first. A problem raises
`EServerConfigError` with every problem in one message, one per line. A valid
factory answers an `IHttp2Server` that is not yet started.

`Build` has two forms. `Build` alone answers a server with no observer, and
`Build(AObserver)` answers a server that sends every event to that observer.

## The server

`IHttp2Server` (`src/Http2Server.Server.pas:43-57`) holds five methods:

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

The implementation is `THttp2Server` (`src/Http2Server.Server.pas:59`), which
owns one `THttp2AsyncServer` (`src/Http2Server.Async.pas:144`).

## The handler

`IHttp2Handler` (`src/Http2Server.Seam.pas:150-154`) holds one method,
`Handle(const ARequest: IServerRequest; const AResponse: IServerResponse)`.
The handler is synchronous: it reads the request, writes the response and
returns. No coroutine and no continuation is part of the contract.

The handler runs on a handler-pool thread. A handler that runs on an IO thread
would hold the connection lock and stall the pool, so the pool checks the rule
at dispatch (`src/Http2Server.Admission.pas:790`).

## The observation events

`IHttp2ServerObserver` (`src/Http2Server.Observer.pas:78-82`) holds one
method, `OnEvent(const AEvent: TServerEvent)`. The server raises one event per
state change that a caller acts on. `TServerEventKind`
(`src/Http2Server.Observer.pas:34-58`) names eleven kinds:

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

`OnEvent` runs on the thread that raised the event. That thread is an IO
thread, a handler-pool thread, or the caller of `Start` and `Stop`. A slow
`OnEvent` slows that thread, and on an IO thread it can delay the wake-up of a
connection. An observer that blocks belongs on its own queue.

`TNullServerObserver` (`src/Http2Server.Observer.pas:84`) discards every event.
A server with no observer carries no observation cost.

The connection events come from `THttp2ConnectionEvents`
(`src/Http2Server.Async.pas:270-300`), and the queue events come from
`THandlerPool` (`src/Http2Server.Admission.pas:723`).

## The statistics

`TServerStats` (`src/Http2Server.Observer.pas:93`) holds four gauges and four
totals.

The gauges count what the server holds now: `BusyHandlers`, `QueueLength`,
`OpenConnections` and `OpenStreams`. The totals count every event since the
build and never decrease: `RefusedTotal`, `TimedOutTotal`, `ResetTotal` and
`TrippedTotal`.

`THttp2Server.Stats` (`src/Http2Server.Server.pas:152`) reads the handler-pool
counters, the connection counter of the async server, and the stream, reset
and trip totals.
