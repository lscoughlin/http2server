---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, sse, server-sent events, event stream, keep-alive, back-pressure
notes:
  - This document describes the event stream of the server, the encoder rules, the thread model, the keep-alive, the back-pressure and the close rules.
  - The format is the one of the WHATWG HTML Living Standard section 9.2, checked on 2026-10-22. The plain-text copy is doc/references/whatwg-html-server-sent-events.txt.
scope: The format rules that the encoder enforces, the stream interface, the threads, the keep-alive, the stall rule and the close rules.
primary_types:
  - ISseStream
  - TSseEvent
  - ESseError
related_docs:
  - seam.md
  - threading.md
  - public-api.md
---

# Server-sent events

A handler turns a response into an event stream with `StartSse`
(`src/Http2Server.Sse.pas`). The handler returns at once. Any thread then sends
events to the `ISseStream`. An event stream holds no handler thread and no
thread of its own.

## The stream

`StartSse` detaches the stream (see [seam](seam.md)), answers with status `200`,
the content type `text/event-stream` and the cache control `no-store`, and
returns an `ISseStream`. The response has no `content-length`. The caller can
pass more headers, for example CORS headers or `x-accel-buffering`.

`ISseStream` has these members:

- `Send` writes one event and answers `srQueued`, `srFull` or `srClosed`.
- `SendComment` writes one comment line.
- `Close` ends the stream after the events that are queued.
- `IsOpen` is false once the stream has ended.
- `LastEventId` is the `Last-Event-ID` request header. The value is empty when
  the header is absent, is not UTF-8, or holds CR, LF or NUL.

The server stores no event. A client that reconnects sends `Last-Event-ID`, and
the application replays the events that the client missed.

Several threads can call `Send`. The stream serialises the calls, and one event
is one write to the channel, so two events never interleave.

## The encoder

The encoder (`src/Http2Server.Sse.Encoder.pas`) holds no socket and no thread.
The format has no escape for a line break, so the encoder splits or rejects.

| Value | Rule |
| --- | --- |
| data | The encoder splits the data at CR, LF and CRLF, and writes one `data:` field for each part. CRLF is one break. Data that ends with a break gives a final empty `data:` field. Empty data gives one empty `data:` field, because an event with no data field fires nothing on the client. |
| id | A CR, LF or NUL raises `ESseError`. A NUL would make the client ignore the whole field. |
| event | A CR or LF raises `ESseError`. |
| retry | The value is written as ASCII digits. A value of 0 writes no field. A negative value or a value over one day raises `ESseError`. |
| text | Every text is UTF-8. Text that is not valid UTF-8 raises `ESseError`. NUL in data raises `ESseError`. |
| comment | A CR or LF raises `ESseError`. |

Every field is written as the name, a colon, one space and the value. The client
removes one space after the colon, so a value that starts with a space keeps it.
Every event ends with one blank line. The stream starts with no byte order mark.
The order of the fields is `retry`, `id`, `event`, then the data.

The server makes no origin check for an event stream. The caller sets CORS
headers.

## HTTP/1.1

The stream runs on both protocols. On HTTP/2 an event is a DATA frame. On HTTP/1.1
the response is chunked, and one event is one chunk. A response to an HTTP/1.0
request has no chunked coding, and the close of the connection ends it. `Close`
sends the last chunk, and the connection serves the next request. The test suite
runs the stream on both protocols (see [http1](http1.md)).

## Threads

The keep-alive and the stall check are timers of one work source of the
streaming pool (see [threading](threading.md)). A pool with one thread serves
the timers of every stream. The test with 1000 open streams and a period of 40
milliseconds shows that one pool thread serves all of them. A timer holds a
reference to its stream until the stream ends, because a pool task holds only a
method pointer.

## The keep-alive

When `SseKeepAliveMs` is above 0, a timer writes the comment `: keep-alive`
after the stream has been idle for that period. An event resets the idle time.
The comment keeps the connection past the idle timeout and keeps a proxy from
closing the stream. The default is 15000.

## Back-pressure and the stall rule

`srFull` means that the outbound queue of the channel passed
`ChannelQueueLimit`. The channel does not queue the event. The producer chooses:
drop the event, try later, or close the stream. The channel calls the drain
notification when the queue falls to `ChannelLowWater`, and the stream then
clears the stall mark.

A stream that stays full for `SseStallTimeoutMs` is closed with an abort. The
check runs on the timer, so the close happens within one timer period after the
limit. The value 0 turns the check off. The default is 30000. A send that the
channel queues also clears the stall mark, so a stream that makes progress is not
closed for an old refusal.

`StartSse` checks the extra header fields before it detaches the response. A header
that is not legal raises an error and leaves no detached stream. If the activation
of the channel fails after the detach, the channel is aborted and frees its slot.

## The close rules

- `Close` closes the channel gracefully. The queued events leave, and the stream
  ends with END_STREAM.
- A reset or a loss of the connection by the peer makes `IsOpen` false. A later
  `Send` answers `srClosed`.
- A half-close of the request by the client does not end the response. A GET
  request ends its own half at once.
- `Stop` closes the stream with the other detached streams (see
  [lifecycle](lifecycle.md)).
- A body on the request is read and dropped. The flow-control credit goes back
  at once.

## Settings

| Setting | Factory method | Meaning |
| --- | --- | --- |
| `SseKeepAliveMs` | `WithSseKeepAlive` | the period of the keep-alive comment; 0 turns it off |
| `SseStallTimeoutMs` | `WithSseStallTimeout` | the time a full stream may stay full; 0 turns the check off |

Both values lie between 0 and one hour.
