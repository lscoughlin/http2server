---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http1, http/1.1, fallback, protocol selection, parser, guard, request smuggling, chunked, keep-alive, staged close
notes:
  - This document describes the HTTP/1.1 fallback, which serves a client that does not speak HTTP/2 on the same listener and with the same handler.
  - RFC 9112 (HTTP/1.1) and RFC 9110 (HTTP semantics) are the sources. Both were checked on 2026-10-22 at https://www.rfc-editor.org/info/rfc9112 and https://www.rfc-editor.org/info/rfc9110. The plain-text copies are in doc/references/.
scope: The protocol selection, the units of the fallback, the parser and its guard, the framing and persistence rules, the limits, the memory bounds, the shared queue, the detached response and what a handler can see.
primary_types:
  - TH1Core
  - TH1Exchange
  - TH1Parser
  - TH1Driver
  - THttp11Limits
related_docs:
  - tls.md
  - admission.md
  - seam.md
  - sse.md
  - configuration.md
  - public-api.md
invariants:
  - The handler contract is the same on both protocols.
  - One connection serves one request at a time, and responses leave in request order.
  - A request that breaks a framing rule is answered once, and the connection closes; the octets behind it are never served.
  - The library never writes a process-wide variable of mORMot2.
---

# The HTTP/1.1 fallback

A client that does not speak HTTP/2 gets HTTP/1.1 from the same listener. The same
handler serves both protocols. The fallback is on by default. The factory method
`WithHttp11Fallback(False)` turns it off.

## Protocol selection

| Transport | Signal | Result |
| --- | --- | --- |
| TLS | ALPN `h2` | HTTP/2 |
| TLS | ALPN `http/1.1`, or no ALPN extension | HTTP/1.1 when the fallback is on; otherwise the connection is refused |
| Clear text | the first 24 octets are the HTTP/2 preface (RFC 9113 section 3.4) | HTTP/2 |
| Clear text | the octets so far are a prefix of the preface | the connection waits; the header deadline bounds the wait |
| Clear text | any other first octets | HTTP/1.1 when the fallback is on; otherwise the connection closes |

The choice is made once for each connection. The function
`SelectCleartextProtocol` (`src/Http2Server.Http1.Select.pas`) decides the
clear-text case from the octets alone. A request line `PRI * HTTP/2.0` without the
rest of the preface is HTTP/1.1, and the guard answers it with status 505.

## The units

| Unit | Task |
| --- | --- |
| `Http1.Parser` | the adapter over the request parser of mORMot2 |
| `Http1.Guard` | the strict rules, as pure functions |
| `Http1.Limits` | the record `THttp11Limits` of the server builder |
| `Http1.Core` | the connection: output queue, keep-alive, close decision |
| `Http1.Exchange` | one request with its response; the `IServerRequest`, the `IServerResponse` and the pool job |
| `Http1.Host` | the cut-able link between an exchange and its core |
| `Http1.ResponseHead` | the response head and its framing, as a pure function |
| `Http1.Channel` | the channel of a detached response |
| `Http1.Driver` | the time-dependent decisions of the connection: close, deadlines |
| `Http1.Select`, `Http1.Status` | the clear-text selection and the reason phrases |

## The parser and the guard

The request parser is `THttpRequestContext` of mORMot2 (`mormot.net.http.pas`,
revision `b2b195da1`). It is the parser of `THttpAsyncServer`, it runs on IO
threads, and it resumes after a read of any size. The adapter drives it one state at
a time with `returnOnStateChange`, so the guard sees the request line before the
header lines, the head before the body, each chunk-size line before its chunk, and
the end of the chunked body. The adapter reads the trailer section itself, because
the parser reads it as one line.

The line scans of the guard resume where the last scan of the same unfinished line
stopped. A sender that trickles one octet at a time into a long header line therefore
costs one comparison for each octet, and not a scan from the start of the line.

The parser of mORMot2 is lenient in places that matter for request smuggling. The
probe tests in `test/Http2Server.Http1.Chunked.Test.pas` record what it accepts
alone:

| Input | The parser alone |
| --- | --- |
| `Content-Length: 5, 6` | reads 5 |
| `Transfer-Encoding:chunked` (no space) | sees no chunked body and leaves the chunk octets unread |
| chunk size line `zz` | reads a positive size and takes the next request as chunk data |
| a trailer field after the last chunk | takes it for the final blank line, and the real blank line starts the next request |

The guard closes each gap. Where an RFC allows two answers, the guard takes the
stricter one, because the parser is a security boundary.

| Topic | Rule | Source |
| --- | --- | --- |
| Line ends | CRLF only. A CR without LF is rejected with 400. A lone LF is not a line end, so a head that uses only LF never completes, and the header deadline closes the connection. A lone LF inside a value is rejected. | RFC 9112 section 2.2 |
| `Content-Length` | exactly one field with one value of `1*DIGIT`. A list, a repeated field, a sign, a space, an empty value or a non-digit gives 400. A value above the body limit or above 18 digits gives 413. | RFC 9112 section 6.3, RFC 9110 section 8.6 |
| `Transfer-Encoding` | only the single value `chunked`, in any case. A field with a list, a parameter or a coding before `chunked` gives 400. An unknown coding gives 501. Several fields give 400. The field in an HTTP/1.0 request gives 400. | RFC 9112 sections 6.1 and 6.3 |
| both fields | 400 | RFC 9112 section 6.3 |
| framing agreement | the parser and the guard must read the same framing, or the answer is 400 | |
| field names and values | a name is a token; a space before the colon, a leading space or tab (obsolete folding), a control octet or DEL in a value, and an empty name give 400 | RFC 9112 section 5 |
| request line | one space between method, target and version; a method over 32 octets gives 501; a target over the line limit gives 414; a space, a control octet, a fragment or a non-ASCII octet in the target gives 400 | RFC 9112 section 3 |
| version | `HTTP/1.0` and `HTTP/1.1` are served; `HTTP/1.2` is served as 1.1; another major version gives 505; a malformed version gives 400 | RFC 9110 section 15.6.6 |
| target forms | the origin form and the absolute form (the authority of the target replaces `Host`); `OPTIONS *`; `CONNECT` gives 501 | RFC 9112 section 3.2 |
| `Host` | HTTP/1.1 needs exactly one valid field; a missing, repeated or invalid field gives 400 | RFC 9112 section 3.2 |
| `Expect` | `100-continue` is accepted in HTTP/1.1; another expectation gives 417 | RFC 9110 section 10.1.1 |
| leading empty lines | at most four before the request line | RFC 9112 section 2.2 |
| chunk-size line | `1*HEXDIG`, then optional extensions in the grammar of the RFC; a size over the chunk limit gives 413; garbage gives 400 | RFC 9112 section 7.1 |
| chunk data | the line after the data must be empty | RFC 9112 section 7.1 |
| trailer | the fields follow the field grammar and are dropped; they are never merged into the head | RFC 9112 section 7.1.2 |

A rejected request is answered once with the status above, `Connection: close` and
a zero length, and the octets that follow are dropped. The test files
`Http2Server.Http1.Head.Test.pas` and `Http2Server.Http1.Chunked.Test.pas` hold the
hostile cases. Each case sends a second request after the defect and checks that it
is not processed. The cases run with the input whole, one octet at a time and in
random pieces, and the three results must be equal. The fuzz test
(`Http2Server.Http1.Fuzz.Test.pas`) mutates valid and hostile requests. It checks
that the parser never raises, that split delivery gives the same result, and that
every accepted head passes an independent strict check. The recorded run used
1,000,000 mutated requests and 250,000 noise inputs.

## One request at a time

A connection serves one request at a time. The octets of later requests wait in the
parser buffer until the response ends, and their number is bounded by
`MaxPipelinedOctets`. Responses leave in request order. A request with
`Connection: close`, an HTTP/1.0 request without `keep-alive`, a framing error, a
cut response or a handler exception ends the connection after the response. After
`Connection: close` the server serves no later pipelined request.

A response that the handler gave a `Content-Length` is sent with that length. Any
other response to an HTTP/1.1 request is chunked. A client of HTTP/1.0 gets a
response that ends with the close of the connection. A response to `HEAD` and a 204
or 304 response have no body; octets that a handler writes for them are dropped. The
handler never sets `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade` or
`Proxy-Connection`; the writer raises for them, and for a header name or value with
CR, LF or NUL.

The server adds a `Date` field to every final response unless the handler set one
(RFC 9110 section 6.6.1). The field is cached and changes once a second. The same
rule applies to HTTP/2.

When a request carries `Expect: 100-continue`, the server sends `100 Continue` when
the handler first reads the body. A handler that answers without a read sends no
interim response. A final response that goes out before the server asked for the
body carries `Connection: close` and ends the connection, because the client may
send the body late or not at all (RFC 9110 section 10.1.1).

A defect in the octets behind the request in progress, such as a pipeline over its
limit or a malformed next request, does not cancel the request in progress. That
request finishes, the connection closes after its response, and the octets behind it
are dropped. A malformed chunk that follows an early response gets no second
response; the connection closes.

While the server stops, an idle connection closes and a request in progress ends
with `Connection: close`.

The parser answers 400 to `Transfer-Encoding:chunked` and `Content-Length:5` written
with no space after the colon. The fields are valid, but the cross-check of the
framing refuses them. The refusal is safe, since no request is smuggled.

## The request cap

`TH1CoreOptions.MaxRequests` (`src/Http2Server.Http1.Core.pas:60`) bounds the
requests of one connection. `BuildH1CoreOptions` sets it from
`MaxStreamsPerConnection` (`src/Http2Server.Async.Options.pas:249`), so the
same factory setting serves both protocols. A value of 0 turns the cap off.

The core counts every admitted request head
(`src/Http2Server.Http1.Core.pas:538`). The exchange that reaches the cap is
served, and its response carries `Connection: close`, as in a drain. The retire
fires once for the connection, and the server raises `seConnectionRetired` with
the stream-cap detail (see [public-api](public-api.md)). A refused head never
reaches the counter, so a defective request does not retire the connection.

## The staged close

A close that follows while the peer still sends would reset the connection and
could destroy the response in the buffer of the peer. After the last octet has left
the socket, the server closes the write side, drops the octets that still arrive,
and closes the connection when the peer closes or after two seconds (RFC 9112
section 9.6). A TLS connection closes at once, because it cannot close one side. The
end of the drain time is checked at the idle check of the connection, so a peer that
never closes ends the connection after one idle period at the latest.

## Limits

The record `THttp11Limits` belongs to the server builder (`WithHttp11Limits`). The
limits are never process-wide variables. The factory validates each value, and it
refuses a limit above the mORMot2 variables `MaxHttpHeaderLineSize` and
`MaxHttpChunkSize`, because the parser would stop at those ceilings anyway. The
library never writes the variables. The test suite shows that two servers in one
process keep their own limits, and that the variables are unchanged after `Start`
and `Stop`.

| Limit | Default | Effect |
| --- | --- | --- |
| `MaxRequestLine` | 8192 | 414 |
| `MaxHeaderLine` | 8192 | 431 |
| `MaxHeaderCount` | 100 | 431 |
| `MaxHeaderOctets` | 65536 | 431 |
| `MaxChunkSize` | 1048576 | 413 |
| `MaxChunkExtension` | 1024 | 400 |
| `MaxTrailerOctets` | 4096 | 431 |
| `MaxBodySize` | 16777216 | 413 |
| `MaxPipelinedOctets` | 65536 | the request in progress finishes, then the connection closes |
| `BodyDeadlineMs` | 30000 | 408 and close |
| `BodyTotalMs` | 300000 | 408 and close; 0 turns the limit off |

`BodyDeadlineMs` counts the time between two arrivals of body octets. A peer that
sends one octet before each deadline passes that limit, so `BodyTotalMs` bounds the
time from the request head to the end of the body (RFC 9112 section 6.3).

A request that stays half read past the header timeout of the factory gets 408 and
a close. A connection that has sent no octet closes silently at the idle timeout.

## Memory

The request body is held in memory until the handler reads it. The parser checks the
body limit before it delivers any octet, so the memory of one request is bounded by
`MaxBodySize`. A request body is not streamed past that limit.

HTTP/2 bounds the unread request body with flow control, because the server sends
`WINDOW_UPDATE` only when the handler reads. HTTP/1.1 has no such mechanism in this
server. The async layer of mORMot2 has no supported call that pauses the reads of
one connection. The result of `OnRead` is checked for `soClose` only, and the poller
subscribes the connection for reads again after every read. A pause would need the
private state of the poller. So the server reads the body as it arrives and holds it,
and the bound is `MaxBodySize` for each connection. This is a deviation from HTTP/2:
a handler that streams a very large upload needs a larger `MaxBodySize` on HTTP/1.1,
and the memory of the server then grows with the number of such uploads.

A client that stops reading a response cannot make the memory of the connection
grow. A handler write waits while the backlog is above `ChannelQueueLimit`. The
backlog is the queue of the core plus the octets that the socket layer of mORMot2
holds back (`PendingWrite`). The test `TestAClientThatNeverReadsBlocksTheHandlerInsteadOfGrowingMemory`
shows that a handler that writes 8 MiB to a client that does not read stays blocked,
and that it finishes when the client reads. Without the second term the handler
finishes at once.

A handler write that sees no progress for the connection write timeout
aborts the connection, so a peer that never reads cannot hold a handler thread
for ever. `BuildH1CoreOptions` sets the bound from
`ServerLimits.WriteTimeoutMs` (`src/Http2Server.Async.Options.pas:251`), and a
zero turns the check off. The once-per-second sweep judges the connection with
the idle rule as well, fed with the write timeout (see
[io-pool](io-pool.md)).

## The shared queue

An HTTP/1.1 request enters the same bounded queue as an HTTP/2 stream and runs on
the same handler threads (see [admission](admission.md)). The queue holds a job for
each HTTP/1.1 request. A full queue, or a wait past the limit, gives 503 with
`Retry-After: 1` and a close. `Stop` refuses the waiting requests with 503 and
cancels the running ones.

## A detached response

`IServerResponse.Detach` works on HTTP/1.1. The handler returns, and the channel
(`TH1ChunkedChannel`) writes the rest of the response. Each `Send` is one chunk, and
a `Send` before the head holds its bytes until `Activate`. `Close` sends the last
chunk and the connection serves the next request. A response to an HTTP/1.0 request
has no chunked coding, and the close of the connection ends the body. The channel
counts against `MaxDetachedStreams`, `Stop` closes it, and a closed socket tells the
sink that the peer is gone. The read side has no data. The documents [seam](seam.md)
and [sse](sse.md) describe the channel and the event stream.

## The upgrade hand-over

A handler can upgrade an HTTP/1.1 request to a WebSocket (see
[websocket](websocket.md)). The exchange then detaches into a `TH1SocketChannel`, and
the core sends the octets that arrive to the channel and no longer to the parser. The
head of the `101` response leaves through the exchange, and the core marks the
connection as upgraded: the exchange ends without a close, and the connection goes on
as raw bytes. While the upgrade is undecided, the core keeps a copy of the octets that go
to the channel, up to 64 KiB. A refused upgrade returns the connection to the parser, and
the parser takes that copy as the start of the next request, because the closed channel
drops its own copy. When more than 64 KiB arrived in the undecided window, the connection
closes after the refusal. The idle check of the driver leaves an upgraded
connection alone.

## What a handler sees

| Item | HTTP/2 | HTTP/1.1 |
| --- | --- | --- |
| `Scheme` | from the transport | from the transport |
| `Authority` | `:authority` | the `Host` field, or the authority of an absolute-form target |
| `Path` | `:path` | the request target |
| `Headers` | the request fields | the request fields in lower case, without `Host`, `Connection`, `Keep-Alive`, `Transfer-Encoding`, `Upgrade`, `Proxy-Connection` and `Expect` |
| `StreamId` | the stream id | an odd number that counts the requests of the connection |
| a reset by the peer | `RST_STREAM` cancels the stream | the close of the socket cancels the request |

## Known limits

- The request body is bounded by `MaxBodySize` and is not streamed past it. HTTP/2
  applies flow control to the unread body; HTTP/1.1 does not (see the section on
  memory).
- A client that stops reading a response loses its connection after the write
  timeout without progress, so its handler thread is not held for ever. The same
  case on HTTP/2 holds the handler thread until the stream or the connection ends.
- `Stop` does not wait for a running HTTP/1.1 request. The pool cancels it after the
  graceful stop timeout, and the connection closes.
- Cancel hooks do not run, as on HTTP/2.
- `Upgrade: h2c` is ignored, and `CONNECT` is answered with 501.
- The server does not rate-limit rejected requests with a token bucket. Each
  rejection ends the connection, so a flood of defective requests costs the sender
  one connection for each rejection.
