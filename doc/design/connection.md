{**
---
license: TBD-LICENCE
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

The unit `src/Http2Server.Connection.pas` holds one connection. The class
`TServerConnectionCore` consumes the bytes of one socket and produces the
bytes of one socket. It holds no socket and it runs no socket call, so a test
drives it without a network.

The IO side calls `Feed` with the bytes a read produced and calls `TakeOutput`
for the bytes to write. The class `THttp2AsyncConnection`
(`src/Http2Server.Async.pas`) holds this bridge.

## The input path

`Feed` (`src/Http2Server.Connection.pas:321`) adds the new bytes to the input
buffer and then walks the frames.

1. The client connection preface comes first. The preface may arrive in
   pieces, so `Feed` copies the bytes into a preface buffer and waits until
   the buffer holds `ClientPrefaceSize` bytes. It then calls
   `CheckClientPreface` (`:355`). A mismatch sends GOAWAY with
   `PROTOCOL_ERROR`. The server SETTINGS frame is the first frame the server
   sends (`src/Http2Server.Connection.pas:362`).
2. A frame header is nine bytes. A partial frame stays in the input buffer
   and waits for the next call.
3. A frame whose length is above `SETTINGS_MAX_FRAME_SIZE` is a connection
   error of type `FRAME_SIZE_ERROR`, and the core removes no payload for it
   (`src/Http2Server.Connection.pas:373-376`; RFC 9113 section 4.2).
4. `ProcessFrame` (`src/Http2Server.Connection.pas:672`) dispatches on the
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
| `DATA` | A frame on an idle stream is `PROTOCOL_ERROR`. A frame on a closed stream is `STREAM_CLOSED`. A non-empty frame on a half-closed stream is `STREAM_CLOSED`. | `ProcessData` |
| `HEADERS` | A frame on a half-closed or closed stream is `STREAM_CLOSED`. A second `HEADERS` frame without `END_STREAM` is `PROTOCOL_ERROR`. A new stream id below `FLastStreamId` is a closed stream. | `ProcessHeaders` |
| `PRIORITY` | The payload is five bytes or the frame is `FRAME_SIZE_ERROR`. Stream zero is `PROTOCOL_ERROR`. A stream that depends on itself is a stream error. | `ProcessPriority` (`:697`) |
| `RST_STREAM` | The payload is four bytes or the frame is `FRAME_SIZE_ERROR`. A frame on an idle stream is `PROTOCOL_ERROR`. | `ProcessRstStream` (`:1000`) |
| `SETTINGS` | An acknowledged frame with a payload is `FRAME_SIZE_ERROR`. | `ProcessSettings` (`:959`) |
| `PING` | Stream zero is required. The payload is eight bytes. An acknowledged frame adds no frame. | `ProcessPing` (`:1032`) |
| `GOAWAY` | Stream zero is required. Every open stream is cancelled, and the core stops. | `ProcessGoAway` (`:1049`) |
| `WINDOW_UPDATE` | A frame on an idle stream is `PROTOCOL_ERROR`. A frame on a closed stream carries no action. A stream window above the maximum is a stream error of type `FLOW_CONTROL_ERROR`. | `ProcessWindowUpdate` (`:1077`) |
| `PUSH_PROMISE` | A server never receives this frame. It is `PROTOCOL_ERROR` (RFC 9113 section 8.2). | `ProcessFrame` |

The core names each fault through `FailConnection` (`:573`). That method
sends GOAWAY, sets `FClosing`, and reports the close to the observer. The IO
side closes the connection after the output drains. A fault never raises an
exception in another thread.

## The stream state machine

A stream is a `TServerStream` (`src/Http2Server.Stream.pas`). Its state is
one of `ssIdle`, `ssOpen`, `ssHalfClosedRemote`, `ssHalfClosedLocal`,
`ssClosed`, `ssResetting` (`src/Http2Server.Stream.pas:41-53`). The core
moves the state and the accessor `State` (`:317`) reads the flags.

- `NewStream` (`:661`) creates the stream in `ssOpen`, adds it to `FStreams`
  and to the index `FById`, and gives it the first reference.
- `CheckStreamId` (`:643`) rejects a new stream id that is even, or that is
  not above the highest id the core accepted. It runs before the closed-
  stream check, so a repeated id stays a repeated id.
- A request header block that ends marks `MarkRequestHead` and the declared
  length. A `DATA` frame that ends with `END_STREAM` marks the remote end.
  A response that ends marks the local end. The state follows those marks.
- `CloseStream` (`:630`) removes the stream from `FById` and from `FStreams`
  and drops the reference of the core. A queue entry and a running handler
  hold their own references, so the stream lives until the last holder
  releases it.

`TServerStream` keeps its own reference count. `AddRef` and `ReleaseRef`
(`src/Http2Server.Stream.pas`) guard the object. Three holders exist: the
core, the admission queue and the running handler. The reference count keeps
a reset that arrives during a handler run from freeing the stream under the
handler.

## The request rules

A complete request header block passes `ValidateRequestBlock` (`:855`). The
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

`TServerConnectionCore` owns one `TFlowControl`
(`src/Http2Server.FlowControl.pas`) and one `TOutputDrain`
(`src/Http2Server.Output.pas`). The drain takes one turn per call and gives
each stream a share of the connection window. The core queues the resulting
frames in `FOutput`, and `TakeOutput` (`:509`) answers them to the IO side.

The wake-up is edge-triggered. The flag `FWakePending` guards one signal per
transition from "no output" to "output" (`:494`). The document
[output](output.md) holds the full rule.

## The connection events

The core reports each state change through the interface `IConnectionEvents`
(`src/Http2Server.Connection.pas:52`): a stream that opens, a stream that is
refused, a stream that resets, a stream that completes, a connection that
closes and a bucket that trips. The class `THttp2ConnectionEvents`
(`src/Http2Server.Async.pas:270`) turns each call into an observer event. The
document [public-api](public-api.md) holds the event list.

## Test seams

The core holds no socket, no thread and no clock of its own. A test builds a
core with `TConnectionCoreOptions`, feeds bytes and reads frames. The class
`TManualMonotonicClock` (`src/Http2Server.Limits.pas`) supplies the time, so
a limit test controls the bucket state. The test unit
`test/Http2Server.Connection.Test.pas` drives the core this way.
