{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, io-pool, async, tls, wake-up, thread-rule
notes:
  - This document describes the IO pool of the server, the mORMot2 async
    classes it extends, the TLS plug-in of a connection and the write wake-up.
  - The document cites the server code as path:line.  The mORMot2 facts cite
    the pinned revision 2ccea1a0e5d7be85bd3cf68e1fd70e9e603d09cc.
scope: The mORMot2 async subclasses, the per-connection core bridge, the TLS handshake, the write wake-up and the thread rule.
primary_types:
  - THttp2AsyncConnection
  - THttp2AsyncServer
  - THttp2ConnectionWaker
  - THttp2ConnectionEvents
  - TTransport
  - TTlsPolicy
db_tables: None.
related_docs:
  - doc/design/threading.md
  - doc/design/tls.md
  - doc/design/connection.md
  - doc/design/output.md
  - doc/design/configuration.md
invariants:
  - The IO pool sweeps connections under the per-connection mORMot lock and never runs a handler.
  - A wake-up reaches the owning IO pool through an edge-triggered flag and one retry after a failed lock.
  - A handler that runs on a marked IO thread raises at once.
  - A TLS connection that did not negotiate h2 is refused.
  - A stalled TLS handshake holds one IO thread for a bounded time only.
---

# The IO pool

The server runs its connection core on the mORMot2 async IO classes. A few IO
threads serve many connections, so the server does not build a poller of its
own and does not need one. The unit `src/Http2Server.Async.pas` holds this
integration.

## The async class set

The server extends four mORMot2 classes. The reading of the pinned revision
`2ccea1a0e5d7be85bd3cf68e1fd70e9e603d09cc` fixes which method does what.

| Class | Role | The methods the server overrides |
| --- | --- | --- |
| `TPollAsyncConnection` | one non-blocking socket | `OnFirstRead`, `OnRead`, `AfterWrite`, `OnClose` |
| `TAsyncConnection` | one connection of a pool | `AfterCreate`, `BeforeDestroy`, `OnLastOperationIdle` |
| `TAsyncConnections` | one thread pool of connections | none |
| `TAsyncServer` | a listener on a port | none; the constructor supplies the connection class |

`TPollAsyncConnection.OnRead` is abstract, so every pool supplies one
(`mormot.net.async.pas:156`). The read path calls it from an IO thread after
mORMot2 moved the socket bytes into `fRd` (`mormot.net.async.pas:2406-2414`).
The write path calls `AfterWrite` from an IO thread after it drained `fWr`
(`mormot.net.async.pas:2533`). `TPollAsyncConnection.OnFirstRead` runs once per
connection, just before the first read, and returns False to close the
connection (`mormot.net.async.pas:1664-1680`). `TAsyncConnection.AfterCreate`
runs when the connection is subscribed and its handle is set; it is cheaper
than the constructor, which mORMot2 reintroduces with its own signature
(`mormot.net.async.pas:1656-1661`, `...:447`).

**The IO thread count.** The server passes the factory value
`IOThreads` as `aThreadPoolCount` to the `TAsyncServer` constructor
(`src/Http2Server.Async.pas:437`). A count above one makes one thread do
`atpReadPoll` and the rest `atpReadPending`; a count of one makes a single
thread do `atpReadSingle` (`mormot.net.async.pas:3030-3038`). mORMot2 always
adds one accept thread and one write thread to the count
(`mormot.net.async.pas:829-831`).

**The idle event.** `TAsyncConnections` runs `IdleEverySecond`, which calls
`ReleaseMemoryOnIdle` on an idle connection and calls
`OnLastOperationIdle` on a connection that passed
`GetLastOperationIdleSeconds` (`mormot.net.async.pas:3832-3905`). The base
class returns zero from `GetLastOperationIdleSeconds`, so the event is
disabled until a subclass enables it (`mormot.net.async.pas:3827-3829`). The
server overrides that method to return the earlier of the factory idle
timeout and the factory header timeout, so the one callback serves both rules
(`src/Http2Server.Async.pas:453-477`). It overrides `OnLastOperationIdle` to
close the connection of a spent timeout (`src/Http2Server.Async.pas:396-416`).

**The backlog.** mORMot2 binds with the global `DefaultListenBacklog`
(`mormot.net.sock.pas:3470`). The server sets it from the factory value
`Backlog` before it binds (`src/Http2Server.Async.pas:441-442`).

## The connection core bridge

`THttp2AsyncConnection` owns one `TServerConnectionCore`
(`src/Http2Server.Async.pas:94`). `AfterCreate` builds the core from the
factory values that `THttp2AsyncServer` prepared at its own construction
(`src/Http2Server.Async.pas:238-262`).

The read path is `OnRead` (`src/Http2Server.Async.pas:295-320`). mORMot2
already decrypted the socket bytes and placed them in `fRd`, so the method
copies that buffer into the core with `Feed` and resets `fRd`. The core keeps
its own partial-frame buffer, so a frame that straddles two reads is
reassembled there. After the feed the method calls `SendPendingOutput`, which
turns handler output into frames.

The write path is `SendPendingOutput` (`src/Http2Server.Async.pas:335-394`).
It drains the core through `DrainPending`, takes the bytes with `TakeOutput`,
and hands them to the mORMot2 write path. The drain runs under the connection
core lock, which every stream also takes, so the HPACK encoder keeps one owner
per connection. The core calls the drain itself at the end of every `Feed`
(`src/Http2Server.Connection.pas:422-430`), so the response to one request
leaves in the same IO turn as the request.

## The write wake-up

The write wake-up follows the mORMot2 pattern. A handler write reaches the
stream host callback (`src/Http2Server.Stream.pas:745`), the core raises one
edge-triggered flag per transition from "no output" to "output"
(`src/Http2Server.Connection.pas:455-468`), and the waker drains the core and
calls the mORMot2 write path (`src/Http2Server.Async.pas:194-200`).

An IO thread that blocks in `epoll_wait` on Linux or `poll` on macOS sleeps
until a socket event arrives. New output on an already writable socket is not
such an event, so without a signal that thread never sends the response. This
is the reason the wake-up exists.

A lost wake-up is the risk of the pattern. The mORMot2 wake-up of a poll
thread sets a counter, tries the guard lock, and runs the wake-up itself when
the lock is free; a request that loses the lock to the running thread is
picked up by the retry at the end of the lock owner
(`mormot.net.async.pas:2761-2773`, `...:4096-4110`). The server follows the
same rule: the send loop records a wake-up that arrives while it runs, and it
repeats until no late wake-up and no queued output remain
(`src/Http2Server.Async.pas:342-393`). A second call of the mORMot2 write path
covers the case where the write lock went to the IO thread
(`src/Http2Server.Async.pas:374-379`).

The stream host callback is the bridge between the two sides
(`src/Http2Server.Connection.pas:230-233`). The host holds the core as a raw
pointer and not as an interface, so the core and the host form no reference
cycle.

## The TLS handshake

The server uses TLS route A. mORMot2 enables TLS with the `acoEnableTls`
option and sets the server context after the socket binds; the handshake then
runs at the first read of each connection
(`mormot.net.async.pas:4309-4310`, `...:4244-4262`). The server adds the option
when the factory names a certificate (`src/Http2Server.Async.pas:435-436`), and
it installs the server context and the ALPN callback in `Start`
(`src/Http2Server.Async.pas:529-541`). The route itself is the subject of
`doc/design/tls.md`.

The handshake blocks the IO thread that runs it. mORMot2 bounds the
`SSL_accept` loop with a 5000 ms deadline
(`mormot.lib.openssl11.pas:12146-12166`). The server clamps the factory
handshake timeout to that bound (`src/Http2Server.Tls.pas:128-139`), and it
also sets the socket send and receive deadlines to the same value before the
handshake starts (`src/Http2Server.Async.pas:273-293`). A client that opens a
socket and sends nothing therefore holds one IO thread for a bounded time
only.

A TLS connection must select `h2`. `OnFirstRead` calls the base method, which
runs the handshake, and then refuses the connection when the negotiated name
is not `h2` (`src/Http2Server.Async.pas:273-293`). No HTTP/1.1 request ever
reaches the HTTP/2 state machine.

## The thread rule

A handler must never run on an IO thread. Such a handler would hold the
connection lock for the length of its work and would stall every other
connection on that IO thread. The seam carries the rule
(`src/Http2Server.Seam.pas:155-171`). The IO callbacks mark their thread at
entry (`src/Http2Server.Async.pas:299`, `...:324`), and the handler pool
checks the mark before it calls a handler
(`src/Http2Server.Admission.pas:761-763`). The check raises in every build,
so a violation fails loudly and never reaches production silently.

## The idle and header timeouts

`THttp2AsyncConnection.OnLastOperationIdle` runs once per second on a quiet
connection (`src/Http2Server.Async.pas:396-416`). It closes a connection whose
first header block did not complete within the factory `HeaderTimeoutMs`, and
it closes an idle connection with no open stream and no queued output. The
close is `TAsyncConnections.ConnectionRemove` (`mormot.net.async.pas:3696`),
because a write to an idle connection would itself need the write lock.

## The poller of each platform

mORMot2 uses `epoll` on Linux and forces the `poll` API on BSD and Darwin
(`mormot.net.sock.posix.inc:36-38`, read 2026-10-07). `poll` costs time in
proportion to the number of sockets in the set, because the kernel scans the
whole set on every call, while `epoll` reports only the ready descriptors. The
relative cost of the two pollers under load is the subject of the load-testing
work, and this document records no measurement, because this host is macOS
aarch64 and the comparison needs a Linux host as well.

## Open verification

The pure TLS decisions and the h2c loopback run in the normal suite
(`test/Http2Server.Async.Test.pas`). The loopback test starts the server on a
loopback port, speaks h2c with the copied frame builders and proves a full
request and a full response. A handler that blocks for five seconds on one
connection still leaves a second connection served. The thread rule has its
own tests. The idle close and the first-header-block close each have a test
that a raw client drives by sleeping, and both checks fail when the timeout
wiring is mutated, so they prove the behaviour and not the timing.

**Open gap.** A live TLS handshake loopback is not yet part of the suite. It
needs a self-signed certificate, generated at test time, and a client that
offers the `h2` ALPN name. The ALPN select rule and the negotiated-name check
carry unit tests, and the h2c loopback proves the pool, but no test yet drives
`h2` through a real OpenSSL handshake on this server. The platform run on
Linux amd64 is also open: this host is macOS aarch64, so the Linux result is a
measured gap of a later validation stage.

## Sources

| Claim | Source | Read |
|---|---|---|
| The async class set, its virtual methods and the thread roles | `third_party/mORMot2/src/net/mormot.net.async.pas` (pinned revision) | 2026-10-07 |
| The 5000 ms `SSL_accept` deadline and the TLS setup order | `third_party/mORMot2/src/lib/mormot.lib.openssl11.pas:11918-12009`, `:12146-12166` | 2026-10-07 |
| The `DefaultListenBacklog` global | `third_party/mORMot2/src/net/mormot.net.sock.pas:3470` | 2026-10-07 |