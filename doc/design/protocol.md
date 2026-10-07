{**
---
license: TBD-LICENCE
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, protocol, frames, hpack, flow-control
notes:
  - This document describes the wire protocol units of the server.
  - The units are copies of the sibling HTTP/2 client units, renamed into
    the Http2Server namespace and reviewed for server use.
scope: The five protocol units and the server-side changes to them.
primary_types:
  - THttp2ErrorCode
  - TFrameHeader
  - TFrame
  - TConnectionSettings
  - THpackCodec
  - TWindow
  - TFlowControl
db_tables: None.
related_docs:
  - doc/design/fpc-runtime.md
invariants:
  - A received frame larger than the advertised SETTINGS_MAX_FRAME_SIZE is a
    connection error of type FRAME_SIZE_ERROR.
  - A decoded header list never exceeds SETTINGS_MAX_HEADER_LIST_SIZE.
  - A flow-control window never exceeds 2^31-1 octets.
---
}
# HTTP/2 Protocol Units

The server carries five protocol units. Each unit holds one concern, uses no
socket and no thread, and is free of the mORMot2 dependency. The units are
copies of the sibling HTTP/2 client units at a recorded revision. The pasdoc
header of every copied file names its source file and its source revision, so
a later merge shows the difference between the copy and its origin.

## Errors

`Http2Server.Errors` holds the wire error codes and the exception hierarchy.
`THttp2ErrorCode` mirrors the code list of RFC 9113 section 7. An
`EHttpError` carries an `ErrorCode` value, which the connection places in a
`RST_STREAM` or `GOAWAY` frame.

The server adds four classes to the copy:

| Class | Base | Meaning |
|---|---|---|
| `EServerConfigError` | `EHttpError` | The factory rejected its own configuration. |
| `EStreamCancelled` | `EHttpStreamError` | The peer cancelled the stream. |
| `EStreamReset` | `EHttpStreamError` | The server sent `RST_STREAM` for the stream. |
| `EServerStopped` | `EHttpError` | The server stopped, so no stream makes progress. |

`EStreamCancelled` and `EStreamReset` descend from `EHttpStreamError`, so a
catch of the stream error class catches both. A caller that requires the
stream identifier reads the `StreamId` property of the base class
(`src/Http2Server.Errors.pas:88-104`).

## Frames

`Http2Server.Frames` freezes the wire format. A frame is a nine-octet header,
`TFrameHeader`, and a payload, `TFrame`, as RFC 9113 section 4.1 defines.

The unit carries the payload builders, the payload parsers and the stream
read and write routines. `ReadFrame` enforces the received-frame limit
(`src/Http2Server.Frames.pas:445`): a frame header that states a length above
the limit raises `EHttpProtocolError` with `ecFrameSizeError` before the
server reads the payload. This check is what stops a peer from asking the
server to allocate an unbounded buffer.

### Client connection preface

A new connection starts with the 24-octet preface of RFC 9113 section 3.4,
`PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`. The unit holds the octets in
`ClientPreface` and offers two entry points:

- `CheckClientPreface(const ABuffer: TBytes): Boolean` compares a buffer of
  exactly 24 octets with the constant.
- `ReadClientPreface(const AStream: TStream)` reads 24 octets and raises a
  protocol error when they differ. A stream that ends inside the preface
  raises `EHttpConnectionClosed`.

### Server settings

`BuildServerSettings` builds the `SETTINGS` frame that the server sends as the
first frame of a connection. It takes a `TConnectionSettings` record, so the
frame carries the values that the factory set and not a default. The frame
uses stream 0 and no ACK flag, as RFC 9113 section 6.5 requires.

## HPACK

`Http2Server.Hpack` holds the HPACK codec of RFC 7541: the static table, the
dynamic table, the integer and string representations, and the Huffman code.
One `THpackCodec` holds one encoder table and one decoder table; no table is
shared between connections.

### The header-list limit

RFC 9113 section 10.5.1 defines the size of a field list as the sum over the
field of 32 octets, plus the name length, plus the value length. A large list
is a denial-of-service vector, so the decoder stops as soon as the running
total passes the cap. `THpackCodec.MaxHeaderListSize` holds the cap, and a
zero value removes it. The check runs inside the append step
(`src/Http2Server.Hpack.pas:726-736`), so the decoder raises
`EHttpProtocolError` with `ecEnhanceYourCalm` part way through a hostile
block instead of building the full list first.

The decoder also obeys the table size that the server advertised through
`SETTINGS_HEADER_TABLE_SIZE`: a dynamic table size update above that value is
a compression error. The encoder obeys the table size of the peer, which the
connection applies through `ApplySettings`.

## Flow control

`Http2Server.FlowControl` holds the window accounting. A `TWindow` carries a
size, a consumed count and the two directions. `TFlowControl` holds one
connection window and one window per open stream.

A window never exceeds 2^31-1 octets. The constant `MaxWindowSize` holds that
value (`src/Http2Server.FlowControl.pas:28`), and both `ApplyUpdate` and
`ApplyInitialWindowDelta` check the new size against it and raise a flow
control error above it.
