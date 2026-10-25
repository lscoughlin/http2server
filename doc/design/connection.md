---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, connection, frames, stream-state, hpack
notes:
  - This document describes the connection core, the unit that turns socket
    bytes into frames and stream state.
  - The document cites the server code as path:line.
scope: The inbound frame path, the stream state machine, the HPACK state of a connection and the fault rules.
primary_types:
  - TServerConnectionCore
  - TConnectionCoreOptions
  - IConnectionEvents
  - TCoreStreamHost
db_tables: []
related_docs:
  - doc/design/protocol.md
  - doc/design/threading.md
  - doc/design/output.md
  - doc/design/seam.md
  - doc/design/admission.md
  - doc/design/io-pool.md
invariants:
  - The core holds no socket. It consumes bytes and it produces bytes.
  - One connection core owns one HPACK encoder and one HPACK decoder.
  - Every frame the core processes runs under the connection lock.
  - A connection fault sends GOAWAY and never raises into another thread.
  - A closed stream leaves the core once the last holder releases it.
---

# The connection core

Two units hold one connection. A class cannot span two units, so the core is
a base class and a derived class. The unit `src/Http2Server.Connection.Core.pas`
holds the base class `TConnectionCoreBase`: the fields, the locks, the output
queue, the write wake-up, the stream table and the connection-level frames
(`GOAWAY`, `RST_STREAM`). The unit `src/Http2Server.Connection.pas` holds the
class `TServerConnectionCore`, which derives from the base and adds `Feed` and
the frame handlers. That unit also declares aliases for the public types of the
base unit, so a caller that uses `Http2Server.Connection` sees the names it saw
before the split.

The class `TServerConnectionCore` consumes the bytes of one socket and produces
the bytes of one socket. It holds no socket and it runs no socket call, so a
test drives it without a network.

The IO side calls `Feed` with the bytes a read produced and calls `TakeOutput`
for the bytes to write. The class `THttp2AsyncConnection`
(`src/Http2Server.Async.pas`) holds this bridge.

## The input path

`Feed` (`src/Http2Server.Connection.pas:79`) adds the new bytes to the input
buffer and then walks the frames.

1. The client connection preface comes first. The preface may arrive in
   pieces, so `Feed` copies the bytes into a preface buffer and waits until
   the buffer holds `ClientPrefaceSize` bytes. It then calls
   `CheckClientPreface` (`:113`). A mismatch sends GOAWAY with
   `PROTOCOL_ERROR`. The server SETTINGS frame is the first frame the server
   sends (`src/Http2Server.Connection.pas:120`).
2. A frame header is nine bytes. A partial frame stays in the input buffer
   and waits for the next call.
3. A frame whose length is above `SETTINGS_MAX_FRAME_SIZE` is a connection
   error of type `FRAME_SIZE_ERROR`, and the core removes no payload for it
   (`src/Http2Server.Connection.pas:130-137`; RFC 9113 section 4.2).
4. `ProcessFrame` (`src/Http2Server.Connection.pas:180`) dispatches on the
   frame type.

The input buffer never grows without a bound. `TConnectionCoreOptions`
holds `InboundBufferLimit`, and a peer that passes the limit meets a
connection error.

## The frame rules

RFC 9113 adds rules that depend on the frame kind and on the stream state.
The core holds each rule in one place.

| Frame | Rule | Code |
| --- | --- | --- |
| any, during a header block | Only `CONTINUATION` may follow a `HEADERS` frame on the same stream (RFC 9113 section 4.3). Any other frame is `PROTOCOL_ERROR`. | `ProcessFrame` |
| `DATA` | A frame on stream zero is `PROTOCOL_ERROR`, whatever its length. A frame on an idle stream is `PROTOCOL_ERROR`. A frame on a closed stream is `STREAM_CLOSED`, except a frame on a stream that the server reset lately: the core ignores it, and the connection window still counts it. A non-empty frame on a half-closed stream is `STREAM_CLOSED`. | `ProcessData` |
| `HEADERS` | A frame on a half-closed or closed stream is `STREAM_CLOSED`. A second `HEADERS` frame without `END_STREAM` is `PROTOCOL_ERROR`. A new stream id below `FLastStreamId` is a closed stream. A refused stream, and a stream that depends on itself, still has its header block decoded. | `ProcessHeaders` |
| `PRIORITY` | The payload is five bytes or the frame is `FRAME_SIZE_ERROR`. Stream zero is `PROTOCOL_ERROR`. A stream that depends on itself is a stream error. | `ProcessPriority` (`:205`) |
| `RST_STREAM` | The payload is four bytes or the frame is `FRAME_SIZE_ERROR`. A frame on an idle stream is `PROTOCOL_ERROR`. | `ProcessRstStream` (`:519`) |
| `SETTINGS` | An acknowledged frame with a payload is `FRAME_SIZE_ERROR`. A frame is a delta onto the settings of the peer. | `ProcessSettings` |
| `PING` | Stream zero is required. The payload is eight bytes. An acknowledged frame adds no frame. | `ProcessPing` (`:551`) |
| `GOAWAY` | Stream zero is required. The open streams finish, the core answers with its own GOAWAY and takes no new stream. | `ProcessGoAway` |
| `WINDOW_UPDATE` | A frame on an idle stream is `PROTOCOL_ERROR`. A frame on a closed stream carries no action. A stream window above the maximum is a stream error of type `FLOW_CONTROL_ERROR`. | `ProcessWindowUpdate` (`:605`) |
| `PUSH_PROMISE` | A server never receives this frame. It is `PROTOCOL_ERROR` (RFC 9113 section 8.2). | `ProcessFrame` |

The core names each fault through `FailConnection` (`:636`). That method
sends GOAWAY, sets `FClosing`, and reports the close to the observer. The IO
side closes the connection after the output drains. A fault never raises an
exception in another thread.

## The stream state machine

A stream is a `TServerStream` (`src/Http2Server.Stream.pas`). Its state is
one of `ssIdle`, `ssOpen`, `ssHalfClosedRemote`, `ssHalfClosedLocal`,
`ssClosed`, `ssResetting` (`TStreamState` in `src/Http2Server.Stream.pas`). The core
moves the state and the accessor `State` reads the flags.

- `NewStream` (`:740`) creates the stream in `ssOpen`, adds it to `FStreams`
  and to the index `FById`, and gives it the first reference.
- `CheckStreamId` (`:722`) rejects a new stream id that is even, or that is
  not above the highest id the core accepted. It runs before the closed-
  stream check, so a repeated id stays a repeated id.
- A request header block that ends marks `MarkRequestHead` and the declared
  length. A `DATA` frame that ends with `END_STREAM` marks the remote end.
  A response that ends marks the local end. The state follows those marks.
- `CloseStream` (`:709`) removes the stream from `FById` and from `FStreams`
  and drops the reference of the core. A queue entry and a running handler
  hold their own references, so the stream lives until the last holder
  releases it.

`TServerStream` keeps its own reference count. `AddRef` and `ReleaseRef`
(`src/Http2Server.Stream.pas`) guard the object. Three holders exist: the
core, the admission queue and the running handler. The reference count keeps
a reset that arrives during a handler run from freeing the stream under the
handler.

## The connection lock

One connection lock guards the core: the stream table, the HPACK codecs, the two
flow-control objects and the output queue. A stream takes the connection lock
first and its own stream lock second, and a thread never takes them in the other
order. Every entry of the core that is not called from `Feed` takes the lock by
itself: `Flush`, `DrainPending`, `TakeOutput`, `HasOutput`, `GracefulGoAway`
(called by the server stop, from a thread that is not an IO thread) and
`QueueRefusalFrame` (called by a handler thread).

**The waker.** The write waker writes to the socket, and that write can block. The
waker therefore never runs with the connection lock held. `NotifyWantsWrite` runs
after the lock is released: a handler write reaches it from the stream host
without the lock, and `QueueRefusalFrame` calls it after `UnlockConn`.

**The output cap.** The option `MaxOutputQueueBytes` bounds the output of one
connection. The core checks its queue at the end of each flush, and the IO side
adds the octets that wait in the socket write buffer. A connection above the cap
ends with a GOAWAY of `ENHANCE_YOUR_CALM` (RFC 9113 section 10.5), the IO side
closes the socket at once, and the queued octets are dropped (`Aborted`).

**The reset charge.** An `RST_STREAM` that a frame of the peer makes the server
send is charged to the reset bucket: a PRIORITY or HEADERS frame that names its
own stream, and a WINDOW_UPDATE that passes 2^31-1 on a stream. The stream closes
after the reset, so a repeat of the frame meets a closed stream.

**The write timeout.** A handler write that waits for room in the stream buffer
ends with `EHttpTimeout` after `WriteTimeoutMs`, as a read ends after
`ReadTimeoutMs`. A peer that stops reading cannot hold a handler thread. A write
that does not reach the mORMot2 write path, after the one retry, ends the
connection, because a frame with a hole cannot continue.

## The refusal and reset rules

**The block of a refused stream.** A header block always runs through the HPACK
decoder, because the dynamic table of the peer already holds its fields
(RFC 9113 section 4.3). A stream above the concurrent-stream limit, a stream
after a GOAWAY and a stream that depends on itself get an `RST_STREAM`, and the
core then decodes the block and drops the fields. The stream id counts as used
for the ordering rule of RFC 9113 section 5.1.1 from the HEADERS frame on, so a
refused id cannot be opened again. A stream that depends on itself is closed and
frees its slot.

**The reset set.** The core remembers the last 256 stream ids for which it sent an
`RST_STREAM` (`TStreamIdSet`). A `DATA` frame for such an id was in flight before
the peer saw the reset, so the core ignores it (RFC 9113 section 5.1). The set
holds a fixed number of ids and drops the oldest, so a peer cannot grow it.

**The trailers.** The request head is the first header block of a stream. It
raises `RequestReady`, which admits the request to the handler pool once. A later
block is the trailer block: the core validates it, keeps it apart from the head
(`TServerStream.Trailers`), wakes a handler that waits for the end of the body
and checks the declared content length. The request head stays as it was.

## The request rules

A complete request header block passes `ValidateRequestBlock` (`:372`). The
function calls `ValidateRequestHeaders`
(`src/Http2Server.RequestValidation.pas`) and reads a verdict.

The verdict holds a validity flag and a declared content length. An invalid
block sends `RST_STREAM` with `PROTOCOL_ERROR`, cancels the stream and closes
it. A valid block records the declared length, and a later `DATA` frame that
passes the declaration is a stream error. The rules come from RFC 9113
section 8.1 and section 8.1.2, and they cover the pseudo-header set, the
pseudo-header order, the lowercase name rule, the forbidden fields, the `te`
field and the `content-length` field. The document
[protocol](protocol.md) holds the field rules.

The call takes a third argument, `AConnectProtocol`, which is true when the server
advertised `SETTINGS_ENABLE_CONNECT_PROTOCOL`. Only then is the pseudo-header
`:protocol` legal (RFC 8441 section 4). It is legal once, with a value that is not
empty, on the method `CONNECT` with `:authority` present, and the verdict then sets
`IsExtendedConnect`. A trailer `HEADERS` block on a stream whose head holds `:protocol`
is a stream error with `PROTOCOL_ERROR` (RFC 9113 section 8.5). A `CONNECT` without
`:protocol` follows the rules it followed before.

## The HPACK state

One connection owns one `THpackConnection`
(`src/Http2Server.HpackConnection.pas`). It holds one encoder and one
decoder, and both live for the connection, because the dynamic table of the
peer depends on every block that was sent and received.

A `HEADERS` frame starts a block (`BeginBlock`). A `CONTINUATION` frame
extends it (`AddBlockPart`). The block ends with `END_HEADERS`, and
`TakeBlock` answers the bytes. The core limits the count of `CONTINUATION`
frames and the total block size, so a peer cannot exhaust memory with one
block (CERT VU#421644).

The codec runs only under the connection lock, so the encoder state stays
consistent when a handler writes and an IO thread reads at the same time.
The handler builds a plain header list, and the IO thread encodes it. The
document [seam](seam.md) states that rule.

## Flow control and output

`TServerConnectionCore` owns two `TFlowControl` objects
(`src/Http2Server.FlowControl.pas`) and one `TOutputDrain`
(`src/Http2Server.Output.pas`). The two objects hold the two directions apart:

| Object | Windows | Spent by | Refilled by |
| --- | --- | --- | --- |
| `FSend` | the windows that the peer grants to the server | the output drain, when it sends `DATA` | a peer `WINDOW_UPDATE`; a peer `SETTINGS_INITIAL_WINDOW_SIZE` changes every stream window by the difference |
| `FRecv` | the windows that the server grants to the peer | inbound `DATA` | the `WINDOW_UPDATE` frames that the server sends |

Both objects open at 65535 (RFC 9113 section 6.9.2). A `SETTINGS` frame never
changes the connection window, so the server announces a connection window above
65535 with a `WINDOW_UPDATE` on stream 0 right after its own `SETTINGS` frame.
A new stream receive window opens at the value that the server announced in its
`SETTINGS`, and a new stream send window opens at the value that the peer
announced.

**The credit rule.** Flow control counts the whole payload of a `DATA` frame,
the pad length octet and the padding included (RFC 9113 section 6.9.1). The
connection window is spent and refilled for every frame at its arrival, whatever
becomes of the frame, so a frame that the server drops (a body over its
declared length, or over the inbound limit) never shrinks the window for good.
The stream window is spent for a frame that reaches the stream. The handler
credits the data octets as it reads them, and the pad length octet and the
padding return to the stream window at once, because no reader sees them.

**The drain rule.** A take from a stream buffer never passes the connection
window that is left at that moment, because `TakeOutbound` removes the octets
before the window is spent, and an octet that does not fit would be lost.

**The SETTINGS rule.** A `SETTINGS` frame is a delta onto the settings of the
peer (RFC 9113 section 6.5.3). `TConnectionSettings.Decode` takes the current
settings as its base. The header runs of a response (`HEADERS` and
`CONTINUATION` frames) follow the smaller of the local maximum frame size and
the maximum that the peer announced. An exception in the output path ends the
connection with its code and never leaves `Feed`.

The drain takes one turn per call and gives each stream a share of the
connection window. The core queues the resulting
frames in `FOutput`, and `TakeOutput` answers them to the IO side.

The wake-up is edge-triggered. The flag `FWakePending` guards one signal per
transition from "no output" to "output" (`:563`). The document
[output](output.md) holds the full rule.

## The connection events

The core reports each state change through the interface `IConnectionEvents`
(`src/Http2Server.Connection.Core.pas:59`): a stream that opens, a stream that is
refused, a stream that resets, a stream that completes, a connection that
closes and a bucket that trips. The class `THttp2ConnectionEvents`
(`src/Http2Server.Async.Events.pas:45`) turns each call into an observer event. The
document [public-api](public-api.md) holds the event list.

## Detached streams

A stream with a sink delivers its DATA payload to the sink on the IO thread, under
the connection lock, and keeps no inbound buffer (`TServerStream.DeliverData`,
`src/Http2Server.Stream.pas`). A reset, a connection error and the loss of the
socket call `Cancel` on the stream, and `Cancel` tells the sink once. The core
raises the loss of the socket through `ConnectionLost`, which the async
connection calls from `OnClose` and the destructor of the core calls again as a
safety net. The document [seam](seam.md) describes the channel and its rules.

A `DATA` frame that has no payload and carries `END_STREAM` also reaches the sink as
`PeerClosed(True)`. The request that holds the stream calls the handler with the
request and the response as interface references, so a handler that takes an interface
of its own cannot destroy either object while the pool still uses it
(`THandlerPool.TakeOne`).

## Test seams

The core holds no socket, no thread and no clock of its own. A test builds a
core with `TConnectionCoreOptions`, feeds bytes and reads frames. The class
`TManualMonotonicClock` (`src/Http2Server.Limits.pas`) supplies the time, so
a limit test controls the bucket state. The test unit
`test/Http2Server.Connection.Test.pas` and
`test/Http2Server.Connection.Flow.Test.pas` drive the core this way.
