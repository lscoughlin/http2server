{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, lifecycle, start, stop, goaway, drain
notes:
  - This document describes the life of one server.
scope: The life of one server from Bind to Stop — the start path, the graceful stop, the GOAWAY broadcast, the drain wait and the shutdown order.
primary_types:
  - IHttp2Server
  - THttp2Server
  - THttp2AsyncServer
db_tables: []
related_docs:
  - doc/design/public-api.md
  - doc/design/io-pool.md
  - doc/design/admission.md
  - doc/design/configuration.md
invariants:
  - Start binds the port and returns; it never blocks for a request.
  - Stop is idempotent. A second call does nothing.
  - Stop sends GOAWAY on every open connection before it waits.
  - The graceful wait is bounded by the graceful stop timeout.
  - A server that stopped is built again, not started again.
  - The handler pool stops before the IO pools, so no handler touches a connection that the IO side already released.
---
# The server lifecycle

The unit `src/Http2Server.Server.pas` holds the life of one server. The class
`THttp2Server` owns one `THttp2AsyncServer`, which owns the IO pools, the
listening socket and the handler pool.

## Start

`THttp2Server.Start` (`src/Http2Server.Server.pas:107`) sets its started flag
and calls `THttp2AsyncServer.Start` (`src/Http2Server.Async.pas:717`).

The async start binds the port on its own thread and waits up to five seconds
for the bind. A failed bind raises from the wait, so `Start` does not return a
server that holds no socket. A certificate file then installs the server TLS
context and the ALPN callback. A TLS context that fails raises
`EHttpConnectionError`.

`Start` returns as soon as the socket is bound. It never waits for a
connection and never serves a request on the caller's thread.

A call after `Stop` raises `EServerStopped`. A socket cannot be bound twice, so
a stopped server is built again rather than started again.

## The port

A factory port of 0 asks the operating system for a free port.
`THttp2AsyncServer.BoundPort` (`src/Http2Server.Async.pas:738`) reads the port
back from the bound socket, so `IHttp2Server.Port` answers the real port after
`Start`.

## The server timeouts

Two timeouts come from the factory and reach the connection through the mORMot2
idle event.

The idle timeout closes a connection that holds no open stream and no pending
output for the whole period. The header timeout closes a connection that
completed no request for the whole period, which bounds the work that a peer
can hold with a partial header block.

`THttp2AsyncServer.GetLastOperationIdleSeconds`
(`src/Http2Server.Async.pas:530`) answers the earlier of the two, in whole
seconds, so the idle event runs at the stricter of the two periods. A period
below one second rounds up to one second, because the event runs once per
second.

`THttp2AsyncConnection.OnLastOperationIdle` (`src/Http2Server.Async.pas:466`)
applies both rules and asks the IO side to remove the connection.

## Stop

`THttp2Server.Stop` (`src/Http2Server.Server.pas:131`) runs four steps in
order.

1. The stop flag is set, so a second call returns at once.
2. `BroadcastGoAway` (`src/Http2Server.Async.pas:663`) reads the live
   connections and queues a GOAWAY frame on each one. The last stream
   identifier in the frame is the highest identifier that the core accepted, so
   a peer keeps the streams below it and expects no new stream. The waker then
   pushes the frame to the socket.
3. `WaitForStreams` (`src/Http2Server.Server.pas:118`) polls the open stream
   total every twenty milliseconds until it reaches zero or the graceful stop
   timeout passes. A quiet server stops at once, and a busy server gets the
   full period.
4. `THttp2AsyncServer.Stop` (`src/Http2Server.Async.pas:731`) stops the handler
   pool and then shuts the IO pools down.

The order matters. The handler pool stops first, so a handler never writes to a
connection that the IO side already released. `THandlerPool.Stop`
(`src/Http2Server.Admission.pas`) ends acceptance, refuses the waiting entries
per the refusal mode, waits for the active handlers up to the graceful timeout,
cancels the rest, and joins the worker threads.

The stop is idempotent at both levels. The caller flag covers `THttp2Server`,
and the queue and pool flags cover the two pools.

## The GOAWAY of a stop

The core sends one GOAWAY frame per connection, and no second frame
(`src/Http2Server.Connection.pas:444`). A connection that already sent GOAWAY,
because of a protocol error, keeps its first frame.

The last stream identifier is truthful. A frame that names a higher identifier
than the core accepted would tell a peer that streams were served that were
never served, so the graceful stop reads
`TServerConnectionCore.LastProcessedStreamId`.

## An example

The three programs in `examples/` show the life of a server.

`examples/hello_server.pas` builds a cleartext server, starts it, serves one
page, and stops it when the caller presses Enter.

`examples/binary_response.pas` answers with a generated byte buffer through
`IBodyWriter`, the pull writer of the response.

`examples/slow_handler.pas` runs a handler that sleeps on a small handler pool
with a shallow queue, so a burst of requests fills the queue and the server
refuses the surplus. The observer of the program counts the refusals.
