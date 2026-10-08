{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, output, drain, frames, flow-control, wake-up
notes:
  - This document describes the response path and the drain.
scope: The response path, the turn of the drain, the flow-control share, the header encoding and the frame building.
primary_types:
  - TOutputDrain
  - TOutputDrainOptions
  - IWriteWaker
db_tables: []
related_docs:
  - doc/design/connection.md
  - doc/design/seam.md
  - doc/design/configuration.md
invariants:
  - The drain takes exactly one turn per call.
  - The caller holds the connection lock for the whole of every call.
  - One HPACK encoder serves one connection.
  - No handler thread runs drain code.
---
}

# Outbound path

The outbound path turns the bytes a handler writes into DATA frames that
obey the flow-control windows of the peer and the frame size the peer
accepts. The unit `src/Http2Server.Output.pas` holds this path.

## The drain

`TOutputDrain.Drain` takes one turn. A turn examines every stream that holds
bytes and gives each of them a share of the connection window.

`TOutputDrainOptions` holds the two values the drain needs.

| Field | Meaning |
| --- | --- |
| `MaxFrameSize` | The largest frame this server sends. |
| `BytesPerTurn` | The share of the connection window one stream takes in a turn. A value of zero lets every active stream take its equal share of the window. |

`Share` is the connection window divided by the count of active streams.
When `BytesPerTurn` is not zero it caps that share. Each stream then sends at
most its share, in as many frames as the peer frame size requires. The turn
starts one stream further on than the last turn, so ten equal streams finish
within one turn of each other.

`DrainStream` reads the stream window first. A stream with no window credit
sends nothing, and the other streams are not affected, because the connection
window is only charged when a frame is actually built.

The peer frame size is the smaller of the server value and the value the
peer states in `SETTINGS_MAX_FRAME_SIZE`. `ApplyPeerFrameSize` records the
peer value and `EffectiveFrameSize` reports the smaller of the two.

## Waking the IO thread

`IWriteWaker` has one member, `Signal`. The handler side calls
`TOutputDrain.NotifyWrite` once per transition from "no output" to "output".
The flag `FWakePending` makes this mark edge-triggered, and `TakeOutput`
clears the flag, so a write that adds nothing to an already pending
connection raises no wake-up.

## Headers

The HPACK encoder stays with the connection
(`src/Http2Server.HpackConnection.pas`), so one encoder serves one connection
and the encoder state follows wire order. `THpackConnection.BuildHeaderRun`
splits an encoded block into one HEADERS frame and the CONTINUATION frames
that follow it. No other frame can appear between the frames of one run,
which the HPACK decoder of the peer requires.

This unit therefore builds DATA frames only.

## Frame building

`BuildDataFrame` builds each DATA frame. A body larger than the effective
frame size becomes several DATA frames. A stream that asked to finish sets
END_STREAM on the last frame that carries its bytes, or on an empty DATA
frame when its buffer is already empty.

A handler that writes more than the outbound buffer holds blocks in
`TServerStream.Write` until the drain moves bytes out of the buffer. The
stream waiter of that stream carries the wake-up from the drain to the
handler.

## See also

- `doc/design/connection.md` states how the core feeds and drains one
  connection.
- `doc/design/seam.md` states the boundary between the IO thread and a
  handler thread.
- `doc/design/configuration.md` states the factory values that reach this
  unit.
