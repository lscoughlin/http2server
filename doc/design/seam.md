---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, seam, threads, cancellation, backpressure
notes:
  - This document describes the IO and handler seam and the stream buffers.
  - The seam exists so that the connection core stays free of sockets and of
    the handler pool, and so that the protocol units never need to know how a
    handler blocks.
scope: The handler-facing interfaces, the blocking waiter, the cancel workers and the per-stream buffers.
primary_types:
  - TWaitResult
  - IStreamWaiter
  - TCancelHook
  - IBodyWriter
  - IServerRequest
  - IServerResponse
  - IHttp2Handler
  - IStreamHost
  - TBlockingWaiter
  - TCancelWorkerPool
  - TStreamState
  - TServerStream
  - IDuplexChannel
  - IChannelSink
  - IChannelRegistry
  - THttp2StreamChannel
db_tables: None.
related_docs:
  - doc/design/protocol.md
  - doc/design/limits.md
invariants:
  - The sequence of a stream wait has four members, and no other unit waits on a stream.
  - The wait result names a signal, a timeout or a cancellation, and never a mixture.
  - A handler call holds no lock across a wait.
  - A cancellation raises its exception in the handler thread.
  - A detached stream returns receive credit only when its owner calls ReturnCredit.
  - A sink never blocks. Its data calls run on an IO thread under the connection lock, and PeerClosed can run on any thread.
  - A pending channel sends no DATA frame before its HEADERS frame.
---

# The seam

The server separates its two thread roles by one narrow set of interfaces. The
interfaces live in `Http2Server.Seam`. They carry bytes and they carry no text
encoding, so a body of arbitrary octets crosses the seam unchanged.

The IO side owns a socket, the connection lock and every protocol structure.
The handler side runs a synchronous handler that may block. The seam gives
each side the small part of the other that it needs, and hides the rest.

```pascal
IServerRequest  = interface
  function  Read(var ABuffer; const ACount: Integer): Integer;
  function  ReadChunk(out AChunk: TBytes): Boolean;
  function  BodyIsComplete: Boolean;
  function  IsCancelled: Boolean;
  function  StreamId: LongWord;
  function  Headers: THeaderBlock;
  property  Principal: string;   // read-write; see access-log.md
  property  ClientCertificate: IClientCertificate;   // read-only; nil when none; see mtls.md
  ...
end;

IServerResponse = interface
  procedure SendHeaders(const AStatus: Integer; const AHeaders: THeaderBlock;
    const AEndStream: Boolean = False);
  procedure Write(const AData: TBytes); overload;
  procedure Write(const ABuffer; const ACount: Integer); overload;
  procedure SetBodyWriter(const AWriter: IBodyWriter);
  procedure Finish;
  procedure RegisterCancelHook(const AHook: TCancelHook);
  ...
end;
```

A `Read` answers the number of bytes that arrived, `0` at the end of the body,
and an exception when the stream is cancelled or the read deadline passes. A
`Read` that must wait calls the stream waiter and releases every lock first, so
the connection lock stays available to the IO thread during a handler wait.

## The waiter

`IStreamWaiter` has four members and no more.

```pascal
IStreamWaiter = interface
  function  Wait(const ATimeoutMs: Integer): TWaitResult;
  procedure Signal;
  procedure Cancel;
  function  IsCancelled: Boolean;
end;
```

The small surface is deliberate. The waiter is the only place where a stream
sleeps, so it is the only place that a lock held across a wait could deadlock
the IO thread. `TBlockingWaiter` implements the interface with a
`TCriticalSection` and an `RTLEvent`. `RTLEvent` is the portable choice on
macOS, where `TEvent` is unreliable.

`Wait` answers `wrCancelled` at once when the cancel flag is already set,
answers `wrSignalled` when a signal arrived with no waiter parked, and parks
on the event otherwise. `Signal` sets the pending flag under the lock before
it touches the event, so a signal is never lost. `Cancel` sets the cancel flag
and the pending flag, wakes the event, and only then queues the cancel hooks.
That order means that every wait which returns for any reason already sees the
new flag.

## Cancellation

A cancellation raises its exception in the handler thread. The handler thread
is the thread that must unwind its own stack, so no other thread raises into
it. `Cancel` sets the flag, and the parked wait returns `wrCancelled`; the
handler call then raises `EStreamCancelled` on the handler thread.

A handler may hold a resource that only a separate thread can release — a
database call, for example. `RegisterCancelHook` gives such a handler a hook
that runs on a cancel worker thread of `TCancelWorkerPool`. The pool takes the
hooks from a queue and runs them on its own threads, inside a `try` block, so a
hook that raises disturbs nothing else.

The hooks are a best effort. A handler that blocks with no hook registered
runs on to completion, and the response is discarded after it returns. This
limit is stated in the interface comment and in this document, because the
server cannot interrupt arbitrary handler code.

## Detached streams

A synchronous handler owns a thread from the dispatch to the return of `Handle`.
A stream that lives for minutes, such as an event stream or a WebSocket, cannot
afford that thread. `IServerResponse.Detach` (`src/Http2Server.Seam.pas`) ends the
synchronous life of the handler and gives the stream to an `IDuplexChannel`
(`src/Http2Server.Duplex.pas`). The handler returns. The server keeps the stream
open and moves bytes in both directions without a thread for the stream.

A handler that never calls `Detach` keeps the synchronous contract, with one change
that comes from the loss of the socket. When the socket closes, the connection
core cancels every open stream (see "Connection loss" below), so a handler that
waits on a stream wakes with `EStreamCancelled` at once and not at its next
timeout. This is the cancellation on connection loss that the design always
described. The response object belongs to the handler call and is gone when
`Handle` returns, so a caller that wants to act later keeps the channel and not
the response.

```pascal
IDuplexChannel = interface
  function  Send(const AData: TBytes): TSendResult;      // never blocks
  procedure Close(const AMode: TChannelClose);           // ccGraceful, ccAbort
  function  IsOpen: Boolean;
  function  State: TChannelState;                        // csPending, csActive, csClosed
  function  QueuedBytes: Int64;
  procedure SetSink(const ASink: IChannelSink);
  procedure ReturnCredit(const ACount: Int64);
  procedure Complete(const AStatus: Integer; const AHeaders: THeaderBlock;
    const ABody: TBytes);
  procedure Activate(const AStatus: Integer; const AHeaders: THeaderBlock);
end;

IChannelSink = interface
  procedure BytesReceived(const AData; const ACount: Integer);
  procedure PeerClosed(const AClean: Boolean);
  procedure WriteDrained;
end;
```

The HTTP/2 implementation is `THttp2StreamChannel`
(`src/Http2Server.StreamChannel.pas`). It wraps one `TServerStream` and holds
one reference to the stream until the channel is destroyed.

**Sending.** `Send` appends to the outbound buffer of the stream and wakes the IO
side through the stream host. It never blocks. `srFull` means that the buffer
holds bytes and the write would pass its limit; the bytes did not join the queue.
The sink then hears `WriteDrained` once the buffer falls to the low-water mark
(a detached stream takes the factory setting `ChannelLowWater`, 65536 bytes by
default; an ordinary stream takes half of its limit). `srClosed` means that the channel is closed or the
stream ended. A producer on any thread may call `Send`.

**Receiving.** With a sink set, the IO thread delivers the DATA payload to the
sink and keeps no copy in the inbound buffer of the stream. The data call runs on
the IO thread while the connection lock is held, so the sink does its work
quickly, never blocks, and queues any real work on a work source of the streaming
pool. `PeerClosed` can run on any thread: the IO thread, the owner thread that
aborts the channel, a handler-pool thread that refuses the stream, or the thread
that frees the connection.
Bytes that arrive before `SetSink` wait in a small buffer of the channel, and
`SetSink` delivers them first, in order. `PeerClosed(True)` reports END_STREAM
from the peer. `PeerClosed(False)` reports that the stream ended without it: a
reset, a connection error, the loss of the socket, or the abort of the owner.
A GET that arrived with END_STREAM counts as closed by the peer at once.

**Credit.** The connection window returns when the bytes are buffered, as for
every stream. The stream window returns only when the owner calls
`ReturnCredit`, which adds to the consumed counter of the stream and wakes the IO
side, so a `WINDOW_UPDATE` leaves although the peer is silent while it waits. A
consumer that is slow to call `ReturnCredit` slows its peer and no other stream.

**Pending and active.** A handler that calls `Detach` before `SendHeaders`
receives a pending channel. No response has left yet. `Send` holds the bytes in
the channel, so no DATA frame can leave before the HEADERS frame. `Activate`
sends the headers and then the held bytes. `Complete` answers with an ordinary
response (status, headers, body) and ends the channel, and the connection serves
its other streams. A handler that calls `Detach` after `SendHeaders` receives an
active channel.

**Closing.** `ccGraceful` queues END_STREAM after the buffered bytes. The channel
ends when the peer has ended its half too. `ccAbort` resets the stream with
`RST_STREAM` and `CANCEL`. A pending channel always aborts, because it has no
response to finish. After `Detach`, every other method of the response raises.

**The registry.** `IChannelRegistry` (`TChannelRegistry`) counts the live
channels against a limit and keeps a list. `Detach` raises `EDetachRefused` when
the limit is reached. The slot returns when the channel ends. `CloseAll` closes
every registered channel, which the stop of the server uses.

**Connection loss.** When the socket closes, the connection core cancels every
open stream (`ConnectionLost`, `src/Http2Server.Connection.Core.pas`). A handler
that waits on a stream wakes with `EStreamCancelled`, the cancel hooks run, and
the sink of a detached stream hears `PeerClosed(False)`.

**Lifetime.** A detached stream can outlive its connection. The stream and the
core therefore share the connection lock through a reference count
(`TConnectionLock`, `src/Http2Server.StreamHost.pas`), and the core cuts the
stream callbacks (`ReleaseHost`) before it frees anything they reach. A call on a
channel after the connection ended finds a live lock, a callback that does
nothing, and a channel that reports itself closed. The
adapter never holds a lock while it calls into the core: it counts the calls in
flight, and `ReleaseHost` waits (for a bounded time) until the count is zero. A
lock held across the call would invert the lock order, because a call takes the
connection lock and the connection lock is taken first.

**HTTP/1.1.** An HTTP/1.1 response detaches into a `TH1ChunkedChannel`
(`src/Http2Server.Http1.Channel.pas`). The channel has the same contract: `Send`
returns `srQueued`, `srFull` or `srClosed`, a pending channel holds bytes until
`Activate`, `Close` ends the response, and the sink hears of the end of the
connection. The read side has no data. The document [http1](http1.md) describes
it.

**The registry and the work source.** A channel answers `Registry`, the
registry of the server that holds it. The registry hands out a new work source
of the streaming pool (`NewSource`) and carries the settings that a stream layer
reads, `SseKeepAliveMs` and `SseStallTimeoutMs`. A stream layer such as the event
stream (see [sse](sse.md)) posts its timers to such a source, so it needs no
thread of its own. The registry answers a nil source when the server has no
pool.

**Lock order.** The connection lock comes first and the channel lock second. The
channel never calls a stream method while it holds its own lock, because a
stream method takes the connection lock.

## Stream buffers

`TServerStream` holds the two bounded buffers of one stream. The IO side
appends received bytes with `DeliverData` and takes response bytes with
`TakeOutbound`. The handler side takes body bytes with `Read` and appends
response bytes with `Write`.

```pascal
TServerStream = class
  procedure DeliverData(const AData: TBytes; const AEndStream: Boolean);
  function  Read(var ABuffer; const ACount: Integer): Integer;
  procedure Write(const AData: TBytes); overload;
  ...
  function  InboundWouldOverflow(const ACount: Integer): Boolean;
  function  TakeOutbound(out AData: TBytes; const AMaxBytes: Integer): Boolean;
end;
```

The buffers are bounded, and the bound is the backpressure. A handler that
writes faster than the peer reads fills the outbound buffer and then parks in
the write until the IO thread drains the buffer. The IO side stops reading a
stream whose inbound buffer is full, so a slow handler becomes a growing
connection window rather than unlimited memory.

Every buffer call holds the per-stream lock for the length of the copy only.
The lock is released before a wait, so the IO thread is never blocked by a
handler that sleeps. `MaxLockDepth` records the deepest hold that ever
occurred, and the test suite reads it to confirm that no wait ran under a
lock.

A handler read that moves bytes calls `IStreamHost.WindowUpdatePending` with
the consumed count. The connection owns the credit, so the handler reports what
it consumed and the IO thread decides when to emit `WINDOW_UPDATE`. The
consumed count is cleared by `ClearConsumed` after the frame goes out.

## Content coding

The seam carries bytes and never inspects them, so a content coding is the
affair of the handler. `src/Http2Server.Encoding.pas` gives the handler the
codecs to do that work:

- `NegotiateEncoding(AcceptEncoding)` reads a request's `accept-encoding`
value and answers the coding to use, with the quality rules of RFC 9110
section 12.5.3. An absent or empty value yields `ceIdentity`, so a peer that
offered no coding is never sent one. `HeaderValueOf(ARequest.Headers,
'accept-encoding')` reads the value from the request block.
- `CompressFor(Coding, Bytes)` codes a complete body, and
`GzipCompress`/`DeflateCompress` code one directly.
- `TCompressingBodyWriter` wraps another `IBodyWriter` and codes every
chunk, so a large body is coded as it streams. It is handed to
`IServerResponse.SetBodyWriter`. The gzip container is closed when the
inner writer is exhausted, so the footer reaches the peer before the
response ends.

The library never codes a body on its own. Auto-coding would fight the
handler authority of the seam, and it cannot know the coded size for a
streamed body. A handler that codes a body sets `content-encoding` itself
and sends no `content-length`, because HTTP/2 delimits the body by
END_STREAM.

The example server shows the path: the route `/gzip` negotiates from
`accept-encoding`, codes the body, and answers with `content-encoding` when
a coding was chosen.

## Test seams

The waiter records `WaitCount` and `SignalCount`; the cancel pool records
`WorkerCount`, `CompletedCount` and `MaxRunningCount`; the stream records
`MaxLockDepth`. The suite reads these counters instead of inspecting internal
state, so the tests assert the documented behaviour and not the shape of the
implementation.
