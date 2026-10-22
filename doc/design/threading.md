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
  - TStreamPool
  - IStreamSource
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
  - The streaming pool runs the tasks of one source one at a time, in order, and one task per turn.
---

# Threads

The server runs four kinds of thread. Each kind owns one part of the work, and
the seam is the only place where the kinds meet.

| Role | Count | Responsibility |
| --- | --- | --- |
| IO thread | one per IO pool thread | sweeps connections, reads and writes frames, runs HPACK |
| handler thread | one per handler pool thread | runs one synchronous handler per request |
| cancel worker | one per cancel pool thread | runs the cancel hooks of cancelled streams |
| streaming thread | one per streaming pool thread (default 1) | runs the application work of detached streams |

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

A reset, a client `GOAWAY`, the loss of the socket and a server shutdown all
cancel streams. The cancel path sets a flag on the stream and wakes the waiter. The parked call returns
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

**Known limit.** The running server does not create a `TCancelWorkerPool` and
attaches none to the waiter of a stream, although the factory holds the setting
`CancelWorkerThreads`. A hook that a handler registers through
`RegisterCancelHook` therefore does not run in the server today. A test attaches
a pool to a waiter by hand and shows the hook behaviour of the unit.

## The streaming pool

`src/Http2Server.StreamPool.pas` holds a pool for work that outlives one
request, such as the callbacks of a long-lived stream. The pool is separate from
the handler pool. It uses no admission queue and no handler thread, so a burst
of streaming work cannot delay or refuse an ordinary request. The unit depends
on the monotonic clock of `Http2Server.Limits` and on the thread marks of
`Http2Server.Seam`. It does not depend on the connection core.

The unit of scheduling is a work source (`IStreamSource`). A source is one
ordered task queue. A caller posts a task with `Post`, or posts a task that
becomes ready after a delay with `PostAfter`. Both calls are safe from any
thread, also from inside a task.

- A source waits once in the ready queue when it has tasks. A pool thread takes
  a source, runs one task, and puts the source back at the end of the ready
  queue when more tasks wait. Sources therefore take turns, and a long queue of
  one source does not starve another source.
- One thread works on a source at a time, and the tasks of a source run in the
  order of posting. A task that posts a follow-up task to its own source queues
  that task behind the tasks of the other sources.
- A timer is a task with a deadline. The deadlines sit in a min-heap. A thread
  with nothing to run parks until the first deadline, with a bound of 250
  milliseconds. A timer that fires queues its task behind the tasks that already
  wait in the source.
- The pool size is the number of threads. A pool of size 0 starts no thread, and
  `RunOne` runs one ready task on the calling thread. Tests use this form with a
  manual clock, so the order of tasks is exact and no test sleeps.
- A task runs with the stream-thread mark set (`Http2IsStreamThread`).
  `Http2AssertStreamThread` raises on an IO thread and outside the pool.
- A task that raises never ends a pool thread. The error goes to `OnTaskError`
  and to the error counter.
- `Close` on a source drops its waiting tasks and its timers and refuses later
  posts. `Stop` on the pool refuses posts, drops everything that waits, lets a
  running task finish, and waits for the threads. A task cannot call `Stop`,
  because the call would wait for the thread that runs it. A source stays safe
  to call after its pool is gone, and it then answers as closed.

The pool lock is the innermost lock. A caller can post while it holds the
connection lock, and a pool thread runs a task with no pool lock held.

### The tasks of a WebSocket session

A WebSocket session is a work source of this pool. Its tasks are `Init`, each
message, each Pong and the `Closed` call. The tasks of one session run one at a
time and in the order of the events, and sessions take turns. With the default pool
size of 1, one thread runs the callbacks of every session in turn. A callback that
blocks, for example a database call in `Init`, delays every session and every timer
of an event stream, and the application raises `StreamPoolSize` for such callbacks.
A callback never runs on an IO thread. The IO thread parses the frames, answers Ping
and Close, and queues the data messages. The time limit of `Init` runs on one
watchdog thread of the server and not on the pool, because `Init` can hold every pool
thread. The lock of a session guards its flags and its queue only, and the session
never holds it across a call into the channel or the handler.

## Wake-up safety

The wake-up follows the mORMot2 pattern. The IO thread sets a pending flag
under the connection lock and then signals the waiter. The waiter checks the
flag under its own lock before it parks, so a signal that arrives between the
check and the park is never lost.

A waiter that answers `wrTimeout` re-checks the cancel flag and the pending
flag before it returns, so a signal or a cancellation that races with the
deadline still wins.
