---
license: LGPL-2.1-only WITH Independent-modules-exception
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
  - doc/design/websocket.md
invariants:
  - Start binds the port and returns; it never blocks for a request.
  - Stop is idempotent. A second call does nothing.
  - Stop sends GOAWAY on every open connection before it waits.
  - The graceful wait is bounded by the graceful stop timeout.
  - A server that stopped is built again, not started again.
  - The handler pool stops before the IO pools, so no handler touches a connection that the IO side already released.
  - A retired connection closes once its streams drain or when the retire grace passes.
---
# The server lifecycle

The unit `src/Http2Server.Server.pas` holds the life of one server. The class
`THttp2Server` owns one `THttp2AsyncServer`, which owns the IO pools, the
listening socket and the handler pool.

## Start

`THttp2Server.Start` (`src/Http2Server.Server.pas`) sets its started flag
and calls `THttp2AsyncServer.Start` (`src/Http2Server.Async.pas`).

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
`THttp2AsyncServer.BoundPort` reads the port
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
answers the earlier of the two, in whole
seconds, so the idle event runs at the stricter of the two periods. A period
below one second rounds up to one second, because the event runs once per
second.

`THttp2AsyncConnection.OnLastOperationIdle`
applies both rules and asks the IO side to remove the connection.

A third timeout, the connection write timeout
(`ServerLimits.WriteTimeoutMs`, see [configuration](configuration.md)),
reaches the connection through the once-per-second sweep instead of the idle
event. The idle event never sees a busy connection, so the sweep judges the
write progress itself (see [io-pool](io-pool.md)).

## The connection lifetime limits

Two factory settings bound the life of one connection beyond the idle and
header rules: `MaxConnectionAgeMs` and `MaxStreamsPerConnection` (see
[configuration](configuration.md)). Both default to 0, which turns the limit
off.

A retire ends new work on a connection while the work in flight finishes.
One shared retire path serves both settings. The server raises
`seConnectionRetired` once per connection when the retire starts (see
[public-api](public-api.md)).

For HTTP/2 the retire sends GOAWAY with `NO_ERROR` twice. The first frame is
a warning with the last stream identifier 2^31-1, which RFC 9113 section 6.8
recommends for a graceful shutdown. The second frame carries the real last
processed stream identifier after the drain time. The connection closes when
no stream is open and no output is queued. The stream that reaches the cap is
served, and later header blocks are refused with `REFUSED_STREAM`. Such a
refused stream never ran, so a client retries it on a new connection (RFC
9113 sections 5.1.2 and 8.7). When the retire grace (`GracefulStopTimeoutMs`)
has passed and the connection is still open, the server closes it at once. A
grace of 0 closes at once, as `Stop` with a zero wait does.

For HTTP/1.1 the retire drains the core (`BeginDrain`). The current response
carries `Connection: close`, and an idle connection closes once its output
has left. The exchange that reaches the request cap is served with
`Connection: close` in the same way. A connection whose protocol is still
undecided closes at once, because no request has started on it.

The age check runs once per second from the `IdleEverySecond` override
(`src/Http2Server.Async.pas:881`), which walks every connection. The walk is
needed because the idle rule alone never sees a busy connection (see
[io-pool](io-pool.md)). The sweep returns at once when the maximum age is 0
and the connection write timeout is 0. The age starts at accept, and the
time source is the same tick count that the header deadline uses.

The same walk closes a connection whose writes stalled: an HTTP/2 connection
with queued output that made no progress for `ServerLimits.WriteTimeoutMs`
is removed, the queued octets are dropped, and `OnClose` cancels the streams
as it does for every lost connection. An HTTP/1.1 connection keeps its idle
rule, fed with the write timeout. The stream write timeout differs from this
rule: it bounds one blocked write call of one handler, while the sweep
bounds the whole connection (see [connection](connection.md)).

The effective age of one connection is the setting minus a random part of up
to 10 percent, drawn once per connection at accept (`AgeExpired` in
`src/Http2Server.Async.Options.pas:65`, with the decision values in
`TAgeAction` at `src/Http2Server.Async.Options.pas:82`). The effective age is
never longer than the setting, so the setting stays a hard upper bound.

An upgraded connection is exempt from the maximum age. The sweep never
retires an HTTP/1.1 connection that carried a WebSocket upgrade, and it
skips an HTTP/2 connection while a WebSocket stream is open on it. The forced
close never cuts such a stream. When the last WebSocket stream ends, the next
sweep checks the age again. The stream cap still counts a WebSocket stream as
one stream (see [websocket](websocket.md)).

The stream cap differs from the concurrent stream limit. The concurrent limit
bounds the streams that are open at one time. The cap counts every accepted
stream over the life of the connection (HTTP/2) or every admitted request
head (HTTP/1.1). A refused stream never reaches either counter (see
[limits](limits.md)).

RFC 9113 is the source for the GOAWAY and refusal rules. It was checked on
2026-11-06 at https://www.rfc-editor.org/info/rfc9113. The plain-text copy is
doc/references/rfc9113.txt.

## Stop

`THttp2Server.Stop` runs six steps in order.

1. An atomic flag takes the stop, so a second call, also one from another
   thread, returns at once.
2. `THttp2AsyncServer.BeginDrain` makes the server refuse new connections: the
   first read of a connection that arrives after this point closes it. Each
   HTTP/1.1 connection closes after the request that it serves. An idle one
   closes once its output has left. A request in progress finishes, and its
   response carries `Connection: close` when the head is not built yet (RFC 9112
   section 9.6).
3. `THttp2AsyncServer.BroadcastGoAway` reads the live
   connections and queues a GOAWAY frame on each one. The last stream
   identifier in the frame is the highest identifier that the core accepted, so
   a peer keeps the streams below it and expects no new stream. The waker then
   pushes the frame to the socket.
4. `CloseChannels` (`src/Http2Server.Async.pas`) closes every detached stream
   gracefully. The queued bytes and END_STREAM leave, so a detached stream does
   not hold the wait of the next step until the timeout. A WebSocket session
   sends Close 1001 instead and waits for the reply; at the final stop the
   application hears `Closed(1001)`.
5. `WaitForStreams` polls the open stream total and the count of detached
   channels every twenty milliseconds until both reach zero or the graceful stop
   timeout passes. A request that runs on an HTTP/1.1 connection counts as one
   open stream. A quiet server stops at once, and a busy server gets the full
   period.
6. `THttp2AsyncServer.Stop` (`src/Http2Server.Async.pas`) aborts the channels that
   are still open, stops the handler pool, shuts the IO pools down, and stops
   the streaming pool.

The order matters. The handler pool stops first, so a handler never writes to a
connection that the IO side already released. `THandlerPool.Stop`
(`src/Http2Server.Admission.pas`) ends acceptance, refuses the waiting entries
per the refusal mode, cancels the work that still runs, and waits up to one
second for the worker threads. The drain wait of step 5 already used the
graceful time, so the whole stop keeps one deadline: the graceful timeout plus
this wait. A worker that ignores the cancellation is not joined. It ends alone
when its handler returns, and the pool keeps the state that the worker may still
read (`THandlerPool.StuckThreads` counts these workers).

When `Start` fails, the server runs the stop path, so no port stays bound and no
thread stays alive. `IsRunning` is false and a second `Start` raises
`EServerStopped`. The destructor stops the WebSocket environment before it frees
the async server, so the watchdog never calls a freed server.

A handler thread reaches a connection through its waker. Before the connection
state is freed, `TMethodWaker.Detach` waits for a call in flight and blocks
later calls, and the HTTP/1.1 core cuts its exchanges from the host
(`TH1Core.ReleaseHost`). A late write of a handler therefore finds a dead
link and not a freed object.

The stop is idempotent at both levels. The caller flag covers `THttp2Server`,
and the queue and pool flags cover the two pools.

## The GOAWAY of a stop

The core sends one GOAWAY frame per connection, and no second frame
(`TConnectionCoreBase.SendGoAway`). A connection that already sent GOAWAY,
because of a protocol error, keeps its first frame. After the frame the core
refuses every new stream with `REFUSED_STREAM` and still decodes the header
block of the refused stream.

A GOAWAY from the peer does not cancel any stream (RFC 9113 section 6.8). The
last stream identifier of a client names server-initiated streams, and the
server has none. The streams that are open finish. The core answers with its own
GOAWAY, so it takes no new stream, and the IO side closes the connection when the
last open stream has ended.

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
