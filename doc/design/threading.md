{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, threads, io-pool, handler-pool, poller
notes:
  - This document describes the thread roles of the server and the rule that
    keeps each role on its own side of the seam.
  - The counts in this document are the factory defaults. The factory holds
    every default, and the server code holds no limit literal.
scope: The thread roles, the work each role does, and the rules that keep the roles apart.
primary_types:
  - THttp2ServerFactory
  - TCancelWorkerPool
  - TBlockingWaiter
  - TServerStream
db_tables: None.
related_docs:
  - doc/design/seam.md
  - doc/design/limits.md
invariants:
  - The IO pool sweeps connections and never runs a handler.
  - The handler pool runs synchronous handlers and never touches a socket.
  - The HPACK encoder and decoder run only on an IO thread under the connection lock.
  - A wake-up never raises an exception in another thread.
---

# Threads

The server runs three kinds of thread. Each kind owns one part of the work, and
the seam is the only place where the kinds meet.

| Role | Count | Responsibility |
| --- | --- | --- |
| IO thread | one per IO pool thread | sweeps connections, reads and writes frames, runs HPACK |
| handler thread | one per handler pool thread | runs one synchronous handler per request |
| cancel worker | one per cancel pool thread | runs the cancel hooks of cancelled streams |

The IO pool threads come from the async server of mORMot2. That server owns its
own poller — `epoll` on Linux and `poll` on macOS — and it calls the connection
callback from an IO thread when a socket becomes ready. The server therefore
does not build a poller of its own, and it does not need one.

## The IO side

An IO thread sweeps the connections. For each connection it takes the
connection lock with `TryEnter`. A held lock means that another thread is
already working on that connection, so the sweep moves on and returns to the
connection on the next pass. A connection is never processed by two IO threads
at once, and a busy connection never blocks the sweep.

Under the connection lock the IO thread reads the socket, parses frames, feeds
`TServerConnectionCore`, and drains the outbound buffers. The HPACK encoder and
decoder run here and nowhere else, because the dynamic table is shared
connection state. A handler builds a plain header list and never touches the
encoder.

When the IO thread moves bytes on a stream it signals that stream's waiter. It
also signals the waiter when a window opens. The signal is a wake-up and not a
hand-off, so the IO thread never blocks on a handler and never raises into one.

## The handler side

A handler runs on a handler pool thread. The pool takes a request from the
admission queue and runs `IHttp2Handler.Handle` to completion. The handler is
synchronous, so one handler thread serves one request at a time. A handler that
must wait for another request is out of scope for this library.

A handler call blocks in three places: a read with no buffered body bytes, a
write with a full outbound buffer, and a read or write whose window is closed.
Each of those blocks parks on the stream waiter, which releases every lock
first. The handler thread therefore holds no lock while it sleeps.

## Admission

The handler pool has a fixed size and a bounded queue. A new request enters the
queue when the queue has room, and the queue refuses the request when it is
full. The refusal shape is a factory setting: `rmRefuseStream` answers with
`REFUSED_STREAM`, and `rmHttp503` answers with a 503 response.

A request that waits in the queue for longer than the maximum queue wait leaves
the queue and answers with a 503. That answer is the difference between a busy
server and an unresponsive one.

## Cancellation

A reset, a client `GOAWAY` and a server shutdown all cancel streams. The cancel
path sets a flag on the stream and wakes the waiter. The parked call returns
`wrCancelled`, and the handler thread raises `EStreamCancelled` on its own
stack. No other thread raises into a handler thread, because a raised exception
on a foreign stack leaves the handler with no chance to release what it holds.

`TCancelWorkerPool` runs the cancel hooks. Each hook runs on a cancel worker
thread inside its own `try` block, and a hook that raises disturbs nothing
else. The pool size is a factory setting, and the default is small, because a
hook is a rare event.

The hooks are a best effort. A handler blocked inside a database call with no
registered hook runs on to completion, and the server discards the response
after it returns.

## Wake-up safety

The wake-up follows the mORMot2 pattern. The IO thread sets a pending flag
under the connection lock and then signals the waiter. The waiter checks the
flag under its own lock before it parks, so a signal that arrives between the
check and the park is never lost.

A waiter that answers `wrTimeout` re-checks the cancel flag and the pending
flag before it returns, so a signal or a cancellation that races with the
deadline still wins.
