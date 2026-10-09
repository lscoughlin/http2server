{**
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
db_tables: None.
related_docs:
  - doc/design/protocol.md
  - doc/design/limits.md
invariants:
  - The sequence of a stream wait has four members, and no other unit waits on a stream.
  - The wait result names a signal, a timeout or a cancellation, and never a mixture.
  - A handler call holds no lock across a wait.
  - A cancellation raises its exception in the handler thread.
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
