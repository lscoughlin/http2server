---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: websocket, session, frame codec, close handshake, heartbeat, origin policy, init, streaming pool, rfc 6455
notes:
  - This document describes the WebSocket part of the server, which serves a WebSocket on any detached channel, over HTTP/1.1 and over HTTP/2.
  - RFC 6455 (the WebSocket protocol) is the main source. It was checked on 2026-10-22 at https://www.rfc-editor.org/info/rfc6455. The plain-text copy is doc/references/rfc6455.txt. RFC 6454 (the web origin) was checked on the same date at https://www.rfc-editor.org/info/rfc6454.
  - The IANA registry of close codes was checked on 2026-10-22. The copy is doc/references/iana-websocket-registry.xml.
scope: The frame codec, the session contract, the receive path, the closing handshake, the heartbeat, the limits, the origin policy, the Init hook and the settings.
primary_types:
  - IWsSession
  - IWsHandler
  - TWsInitResult
  - TWsOptions
  - TWsReader
related_docs:
  - seam.md
  - threading.md
  - http1.md
  - sse.md
  - configuration.md
invariants:
  - A session runs on any IDuplexChannel and does not know the protocol under it.
  - The handler is called on a thread of the streaming pool, one call at a time for a session, in the order of the events, and never on an IO thread.
  - Exactly one of Closed or Failed ends the conversation, unless the application calls Abort.
  - The server never puts the close codes 1005, 1006 or 1015 on the wire.
  - A message is sent with one write to the channel, so the frames of two messages never mix.
---

# WebSocket

A WebSocket session is a long-lived pair of byte streams on a detached channel (see
[seam](seam.md)). The session parses and builds the frames, answers the control
frames, runs the closing handshake and calls the application. The handshake that
opens the channel depends on the protocol and is described with each protocol. This
document describes the parts that do not depend on it.

## The frame codec

Four units hold the codec. They have no socket and no thread.

| Unit | Content |
| --- | --- |
| `Ws.Frames` | the opcodes, the close codes, the mask, the frame encoder, the fragmenting message encoder and the Close payload helpers |
| `Ws.Utf8` | a UTF-8 validator with three bytes of state, so a character split across fragments needs no buffer |
| `Ws.Parser` | the resumable frame parser; it pushes the unmasked payload of a data frame to a sink and buffers no data frame |
| `Ws.Reader` | the assembly of frames into messages with the size, fragment and UTF-8 checks |

The parser enforces the rules of RFC 6455 sections 5.2 to 5.5 that one frame and the
order of the frames allow: reserved bits and opcodes, masking in the right direction,
the shortest form of the length, control frames of at most 125 octets and with FIN,
and the order of a fragmented message. The reader checks the message size before it
buffers a byte, so a peer that declares a large frame and sends nothing costs no
memory. A text message is checked for UTF-8 while the octets arrive.

The tests of the codec check the frames of RFC 6455 section 5.7, every rule with its
close code, split delivery (whole, one octet at a time and in random pieces) and a
fuzz run of 40,000 random and mutated streams.

### Close codes

The set of codes that a peer may put on the wire follows the IANA registry of
2026-10-22: 1000 to 1003, 1007 to 1014 and 3000 to 4999. The codes 1004, 1005, 1006
and 1015 never appear in a Close frame. The server sends every code of the set
except 1010, which is a client code.

| Code | Use in the server |
| --- | --- |
| 1000 | a normal close |
| 1001 | the server stops (`Stop`) |
| 1002 | a protocol error: a bad frame, a Close payload that RFC 6455 section 5.5.1 forbids, a data frame after a Close frame |
| 1003 | available to an application |
| 1007 | a text message or a Close reason that is not UTF-8 |
| 1008 | a policy limit: a token bucket is empty, or too many messages wait for the application |
| 1009 | a message or a frame is over its limit |
| 1011 | a callback raised, or the Pong did not come |
| 1006 | reported to the application only: the connection ended without a Close frame, or the peer did not answer the Close frame in time |
| 1005 | reported to the application only: the Close frame had no status |

## The session contract

The application gives the server an `IWsHandler` when it accepts an upgrade. The
server creates an `IWsSession` for the connection and calls the handler on a thread
of the streaming pool (see [threading](threading.md)). The calls of one session run
one at a time, in the order of the events. A callback can call `Send`, `Ping`,
`Close` and `Abort`.

| Call | Meaning |
| --- | --- |
| `Init` | the first call; it authorises, chooses the subprotocol and may send a greeting |
| `Message` | a whole message; a text message is valid UTF-8 |
| `Pong` | a Pong arrived |
| `Closed` | the session ended; the code, the reason and whether the closing handshake completed |
| `Failed` | a callback raised an exception; the session closes with 1011 |

`Send` is legal from any thread at any time. It never blocks. It writes all frames of
the message with one call of the channel, so a refusal leaves nothing half written
and the frames of two messages never mix. It answers `srFull` when the outbound queue
is over `ChannelQueueLimit`, and `srClosed` after the session has ended or the Close
frame has gone out. The session does not drop a message by itself. The sender
splits a message into frames of `FrameSize` octets. A Pong and a Close echo are
separate writes, so they do not wait behind a message that is being built.

`Abort` closes the channel at once, with no Close frame and no later callback.
`SetContext` and `Context` keep a value of the application for the life of the
session; the session releases it at the end.

## The Init hook

`Init` is the one hook for authorisation and for the first actions of a session. The
upgrade code checks the syntax, the version and the origin, detaches the stream at
once and returns; the handler of the route returns. No response has gone out. `Init`
is the first task of the session, so it runs on a pool thread, never on an IO thread
and never in the handler of the route. It sees the whole request, including `Cookie`
and `Authorization`, through a read-only copy that the session keeps, and it may
call a database.

- **Accept.** The result names a subprotocol, which must be one of those the client
  offered or empty, and may add header fields. The server sends the handshake
  response; then the frames that `Init` queued leave, in order. `Init` can send a
  greeting, and it can call `Close`.
- **Reject.** The result holds a status (403 when it is 0), header fields and a body.
  The server answers the upgrade with an ordinary HTTP response. `Message` and
  `Closed` never run, and the frames that `Init` queued are dropped. The observer
  gets `seWsRejected` with the status.
- An exception in `Init`, or a subprotocol that the client did not offer, answers
  500 and raises `seHandlerException`.
- A peer that resets the stream, or closes the connection, while `Init` runs ends the
  session. The result of `Init` is dropped, and `Closed` does not run.
- A peer that sends WebSocket octets before the response is in error. The session
  ends and the channel is aborted.
- `InitTimeoutMs` bounds the wait. `Init` may hold every thread of the pool, so a
  timer of the pool could not fire. One watchdog thread for the whole server watches
  the time limits. When the limit passes, the upgrade is answered with 503 and the
  result of `Init` is dropped when it comes. The timeout frees the stream. It cannot
  interrupt a thread that is blocked in a call.

## The receive path

The IO thread that delivers octets parses the frames. It answers control frames at
once: a Ping is answered with a Pong that has the same payload, and a Close frame is
echoed with the same code. It puts each data message on the queue of its session.

- **Credit.** The octets of control frames are credited to the channel at once. The
  octets of data frames are credited while the message is assembled, so a message
  larger than the HTTP/2 window can arrive. When the queue of a session is half full,
  the credit of data octets waits until the application has taken messages.
- **The queue cap.** A session holds at most `QueuedMessages` messages for the
  application. A peer that sends more, because it ignores the window or because the
  protocol has no window, is closed with 1008.
- **The buckets.** One token bucket counts the control frames that arrive (Ping and
  Pong), and one counts the messages. An empty bucket closes the session with 1008
  and raises `seWsBucketTripped`. A Close frame costs no token.

## The closing handshake

- A Close frame from the peer is echoed at once, with the same code when the server
  may send it and with 1000 otherwise. A Close frame with no status is echoed with no
  status. The application hears `Closed` with the code and the reason of the peer and
  `AClean` true. The channel then closes gracefully.
- `Close` from the application sends a Close frame, stops later sends, and waits for
  the Close frame of the peer for `CloseTimeoutMs`. The reply ends the session with
  `Closed(AClean = true)`. A silent peer ends it with `Closed(1006, AClean = false)`
  and an aborted channel.
- A protocol error sends a Close frame with the code of the error and ends the
  session with `Closed(code, AClean = false)`.
- The loss of the transport calls `Closed` with 1006 and `AClean` false. A half close
  of the peer without a Close frame is the same case.
- A data frame after the Close frame of the peer is a protocol error.

## The heartbeat

When a session has had no inbound traffic for `PingIntervalMs`, the server sends a
Ping and waits `PongTimeoutMs`. A Pong clears the wait. A missing Pong closes the
session with 1011 (reason `ping timeout`), and the close wait then ends the session.
A value of 0 for the interval turns the Ping off. The decision is a pure function
(`WsTimerStep` in `Ws.Close`) that the tests call with numbers.

## Stop

`Stop` sends Close 1001 to every open session and waits up to the graceful stop
timeout for the replies. A session that is still open then is aborted, and the
application hears `Closed(1001, AClean = false)` on the thread that stops the server,
because the pool is going away. A session that waits for `Init` closes with 1001 as
soon as `Init` accepts.

## The origin policy

The origin policy decides whether the `Origin` field of an upgrade request passes. RFC
6454 defines the origin, a triple of scheme, host and port, and the field. It gives a
server no rule, so these are policy choices.

| Policy | Rule |
| --- | --- |
| `opSameOrAbsent` (default) | the field is absent, or every origin in it equals the origin of the server |
| `opAllowList` | as above, and an origin in `AllowedOrigins` passes too |
| `opAllowListOnly` | the field is absent, or every origin is in `AllowedOrigins` |
| `opAny` | every origin passes |
| `opNone` | the server makes no check; the application checks in `Init` |

- The origin of the server is built from the scheme of the transport and from the
  `Host` field or the `:authority` value, lowered and with the default port filled
  in. The scheme is never taken from a header. A server that has no usable host
  refuses a request that carries an `Origin` field.
- A request without an `Origin` field passes every policy, because a client that is
  not a browser sends none. The check protects against a browser of another origin.
  It does not identify a client.
- A value is accepted only if it is `null` alone or a list of `scheme "://" host
  [":" port]` separated by single spaces. A path, a query, a fragment, userinfo, a
  comma, an empty member, a port with a leading zero or above 65535, and a host with a
  non-ASCII octet are refused with 400. The literal `null` is refused with 403.
  Upper case in the scheme and the host is lowered before the compare. An explicit
  default port equals the same origin without a port. The compare is of the three
  parts as ASCII text. It does no suffix match, no registered-domain match, no IDNA
  mapping and no IPv6 normalisation.
- More than one `Origin` field is refused with 400.
- A foreign origin is refused with 403. The 81 vectors of the research notes are the
  test list.

## Settings

The record `TWsOptions` belongs to the server builder (`WithWebSockets`). The
defaults live in `Create`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `MaxMessageSize` | 1048576 | the greatest message, in octets, over all fragments |
| `MaxFrameSize` | 65536 | the greatest payload of one frame that the server accepts |
| `MaxFragments` | 1024 | the greatest number of frames of one message |
| `QueuedMessages` | 16 | the greatest number of messages that wait for the application |
| `FrameSize` | 16384 | the payload size of the frames the server sends |
| `PingIntervalMs` | 30000 | the idle time before a Ping; 0 turns the Ping off |
| `PongTimeoutMs` | 10000 | the wait for the Pong |
| `CloseTimeoutMs` | 5000 | the wait for the Close frame of the peer |
| `InitTimeoutMs` | 10000 | the wait for `Init` |
| `ControlBucket` | 100 tokens, 10 a second | Ping and Pong frames that arrive |
| `MessageBucket` | 10000 tokens, 10000 a second | data messages that arrive |
| `OriginPolicy` | `opSameOrAbsent` | see above |
| `AllowedOrigins` | none | the allow-list, each entry `scheme://host[:port]` |
| `Subprotocols` | none | the subprotocols the server picks from, in order of preference |

The factory validates each value and the entries of both lists.

## Counters and events

The statistics hold the open sessions, the messages and the payload octets in each
direction, the sessions closed for a protocol error and the sessions closed for a
missing Pong. The observer gets `seWsOpened`, `seWsRejected` (with the status),
`seWsClosed` (with the code), `seWsFailed` and `seWsBucketTripped`.
