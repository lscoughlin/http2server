---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, validation, h2spec, conformance, interop, evidence
notes:
  - This document records the conformance evidence of the server.
scope: The external tools, the runs and their results, the comparison with the C and FreePascal implementations, and the recorded gaps.
primary_types: []
db_tables: []
related_docs:
  - doc/verification/toolchain.md
  - doc/design/protocol.md
  - doc/design/connection.md
invariants:
  - Every number in the run table comes from one run that is named.
  - Every gap holds the reason and the condition that closes it.
---

# Validation evidence

This file holds the evidence of the HTTP/2 conformance of the server. The
section "Runs and results" records each run of each external tool. The
section "Reference implementation comparison" records the rules that the
server shares with the C and FreePascal implementations. The section
"Recorded gaps" records the checks that did not run and the reason.

The command `task validate` repeats every check in this file. The command
`task validate:fast` repeats the two short h2spec packages only. Each
command compiles the example server, starts it on a free port, and stops it
after the last check. A tool that is absent produces a `SKIP` line with the
name of the tool.

## Tools

| Tool | Version | Purpose |
|---|---|---|
| `h2spec` | 2.6.0 | Section-by-section conformance to RFC 9113 |
| `nghttp` | 1.70.0 | A request from a second implementation |
| `h2load` | 1.70.0 | Many requests over many connections |
| `curl` | 8.7.1 | A request from a widely deployed client |

## Runs and results

The example server is `bin/interop_server`. It answers `/` with a text page,
`/large?bytes=N` with a generated body, `/binary` with every byte value once,
and `POST /echo` with the request body. The `/large` body repeats the byte
pattern `i mod 251` in each 65536-byte chunk, so each chunk starts the
pattern again.

| Check | Command | Result |
|---|---|---|
| Full conformance | `h2spec -h 127.0.0.1 -p PORT http2` | 94 tests, 94 passed, 0 skipped, 0 failed |
| Generic frame rules | `h2spec -h 127.0.0.1 -p PORT generic` | 44 tests, 44 passed, 0 skipped, 0 failed |
| Second implementation | `nghttp -n http://127.0.0.1:PORT/` | A body of 37 bytes, `:status: 200`, and a GOAWAY frame with the code `NO_ERROR` |
| Widely deployed client | `curl --http2-prior-knowledge http://127.0.0.1:PORT/` | Status 200, 37 bytes |
| Large response | `curl --http2-prior-knowledge 'http://127.0.0.1:PORT/large?bytes=8388608'` | 8388608 bytes in 0.0086 s |
| Load | `h2load -n 200 -c 10 -m 6 http://127.0.0.1:PORT/` | 200 requests, 0 failed |

The unit suite adds 376 tests with 0 errors and 0 failures. The suite holds
the local rules; the tools above hold the external rules.

### The stability of the IO pool under abusive load

A sustained abusive load leaves the mORMot2 IO pool threads running and the
server serving. The load is a repeated `h2spec` run together with 300 parallel
sockets that each send a connection preface, SETTINGS and a DATA frame on an
idle stream, and 300 sockets that reset at once. A healthy server holds 11
threads. A stalled server holds 6 to 8 threads, keeps the listening socket
bound, uses no CPU and serves no later connection.

Four rules keep the pool alive.

1. `OnFirstRead` reports a refusal and never raises. The hook sets the
   handshake deadline, and Darwin answers `EINVAL` for `SO_RCVTIMEO` on a
   socket whose peer already sent RST. mORMot2 calls the hook outside any
   `try`, and the pool loop ends the thread on any escape. The test
   `TAsyncServerTest.TestImmediateResetKeepsTheIoPoolAlive` holds the rule:
   64 sockets reset at once, then the server answers a fresh request.
2. A peer GOAWAY is ordinary input, and `ProcessGoAway` answers with a GOAWAY
   of its own. The `h2spec` case `http2/7` "Sends a GOAWAY frame with unknown
   error code" sends a GOAWAY and then a PING, and passes on a PING
   acknowledgement *or* on a connection close. RFC 9113 section 6.8 lets the
   peer keep the connection in use until its last stream ends, and section 7
   holds that an unknown error code triggers no special behaviour. The read
   loop therefore keeps reading after the GOAWAY, and the GOAWAY of the
   server makes the end of the connection visible. The test
   `TConnectionCoreTest.TestClientGoAwayAnswersAndKeepsReading` holds the
   rule, and 30 cold-start full-package `h2spec` runs pass 30 times.
3. `FailConnection` ends every open stream after it sends its GOAWAY. RFC 9113
   section 5.4.1 holds that after the GOAWAY frame of an error condition, the
   endpoint MUST close the TCP connection. The IO side closes a connection
   only when no stream is open, so the open streams must end for the close to
   happen. The test `TConnectionCoreTest.TestConnectionErrorClosesEveryOpenStream`
   holds the rule, and 40 cold-start runs of the whole `http2` package pass 40
   times, with 40 further runs of the `6.2` package also clean.
4. The pinned mORMot2 revision has a fault on aarch64. FPC builds the
   `Interlocked*` calls of a `TLightLock` without a memory barrier, so the lock
   of the pending-event list of the poll does not publish its writes. The run
   `h2load -n 5000 -c 50 -m 10` keeps 500 requests in flight and reports 2067
   of the 5000 requests as failed for that reason. The run
   `h2load -n 5000 -c 50 -m 1` keeps 50 in flight and reports 5000 of 5000
   requests answered, 0 failed, in 0.16 s.

`h2load` is a benchmark and not a conformance tool, so no `h2load` wall time
gates the acceptance. The runs above finish in under one second.

### The HTTP/1.1 fallback

The hostile-input tests send the cases of the research list (cases 1 to 89; case 90
is covered by the response writer tests) to the parser of mORMot2 and the guard.
Each case sends a second request after the defect and checks that the server does
not process it. The input is fed whole, one octet at a time and in random pieces,
and the three transcripts are equal. The probe tests show what the parser of
mORMot2 accepts alone: a list in `Content-Length`, a `Transfer-Encoding` field
without the space, a garbage chunk size that swallows the next request, and a
trailer field that ends the body early. Each gap is closed by a rule of the guard.

The fuzz test mutates 29 seed requests. The recorded run on 2026-10-22 used
1,000,000 mutated requests and 250,000 noise inputs: the parser raised no
exception, split delivery gave the same transcript, and every accepted head passed
an independent strict check. A run with the check on `Content-Length` removed from
the guard failed at the 55th request, which shows that the check can fail.

The live tests (`THttp1LiveTest`, 27 tests) run a server on clear text with a
raw-socket client: keep-alive across ten requests, a POST body, a chunked POST,
chunked responses, `HEAD`, 204 and 304, `Connection: close`, HTTP/1.0, the
`100 Continue` at the first read, pipelining, an oversized head, a slow head, a
handler exception before and after the headers, framing defects, a smuggled
request, `Date`, header injection by a handler, an early answer with an unread
body, a full queue, `Stop`, the fallback off, both protocols on one listener, a
large response, a client that never reads, a client that never reads while the only
handler thread waits for it (the idle period closes the connection and the next
client is served), and `Stop` during a request. The test of the client that never reads showed the effect of
the pending-octet term in the backlog: with the term removed, a handler that writes
8 MiB to a client that does not read finishes at once. The detach tests
(`THttp1DetachTest`, 11 tests) cover the chunked channel and the event stream on
HTTP/1.1.

`task validate` runs the HTTP/2 conformance with a server whose fallback is off,
because case 3.5.2 of `h2spec` sends `INVALID CONNECTION PREFACE`, which a server
with the fallback on reads as an HTTP/1.1 request line and answers with 400. The
run passes the whole `http2` package. The script then starts a server with the
fallback on and checks that `curl --http1.1` and `curl --http2` give the same body
over clear text and over TLS. A server with the fallback off and a certificate
refuses `curl --http1.1` and serves `curl --http2`.

Gaps of this record: the request body of HTTP/1.1 is not streamed past
`MaxBodySize`, because the async layer of mORMot2 has no supported call that pauses
the reads of one connection (see [http1](../design/http1.md)). The run with 1,000,000 mutated requests is not part of `make test`,
which runs 20,000; the environment variable `HTTP1_FUZZ_RUNS` sets the count.

### WebSocket

The unit tests cover the codec (the frames of RFC 6455 section 5.7, every parser rule
with its close code, split delivery, a fuzz run of 40,000 streams), the origin policy
(the 81 vectors of the research notes), the session on a fake channel (37 tests: Init,
reject, the closing handshake with each bad payload, the heartbeat, the queue cap, the
buckets, the credit rule, Stop), the pool (5,000 idle sessions on one thread, the
order of the tasks of a session, the turns of two sessions, four threads that never run
two tasks of one session, Stop) and the HTTP/1.1 handshake on a live server (15
tests: the RFC accept key, each failed check with its status, the origin policy, the
subprotocol rule, a body and pipelined octets, a reject that returns the connection
to keep-alive, no 101 before Init, a greeting, an echo of 100 messages, a Ping, a clean
and an abnormal close, Stop, the detach limit).

The Autobahn fuzzing client (`crossbario/autobahn-testsuite`, wstest 0.10.9) ran
against `examples/ws_echo` on 2026-10-22 over HTTP/1.1, with the limits of the `big`
argument and without compression. The groups 1 to 7, 9 and 10 give 301 cases. The result
is 291 OK, 7 NON-STRICT and 3 INFORMATIONAL, and no failure. The groups 12 and 13 test
`permessage-deflate`, which the server does not offer. The NON-STRICT cases are 3.2, 3.3,
4.1.3, 4.1.4, 4.2.3, 4.2.4 and 5.15: in each, the server first echoes the valid message
that came before the violation, and then closes, which the specification allows. The
INFORMATIONAL cases are 7.1.6, 7.13.1 and 7.13.2, where the specification leaves the
outcome open.

A real browser opened `examples/ws_echo` through `new WebSocket` in Chrome on
2026-10-22: the page reported `open, subprotocol echo`, and the message `hello` came
back as an echo.

### WebSocket over HTTP/2

The unit tests cover the validator rules for `:protocol` (10 tests: the setting, the
method, the authority, a second value, an empty value, the order, the path, a `CONNECT`
without `:protocol`, the `SETTINGS` entry) and the handshake of RFC 8441 on a live
server with a raw frame client (17 tests: the setting with and without
`WithWebSockets`, a stream error without the setting, `:protocol` on another method,
the `200` without `END_STREAM`, an echo and a Ping, a GET and a WebSocket on one
connection, 100 streams on one connection, a close from the client, an `END_STREAM`
with no Close frame, `RST_STREAM`, `Stop`, the refusals with 400 and 403, a `401` from
`Init`, a greeting and a subprotocol, a trailer, a message of 400 KiB under the
default windows, the detach limit).

The client in `tools/validate/ws_h2_client.py` uses the Python packages `h2` 4.4.1 and
`wsproto` 1.3.2. It reads the setting, opens the extended CONNECT stream, sends 50 text
messages, checks 50 matching echoes, closes with 1000 and reads the clean close. The
check ran against `examples/ws_echo` on 2026-10-22 and passed. `tools/validate/run.sh`
runs it when the packages are present.

### The release run

The runs below ran on 2026-10-22 on the final build, on the development host (macOS
aarch64, FPC 3.2.4), at the version 0.24.0.

| Run | Result |
| --- | --- |
| `make test` | 642 tests, no error, no failure |
| `h2spec` (package `http2`, server started with `no-http11`) | 94 of 94 pass, as before |
| `tools/abuse/abuse.py` (strict profile) | 8 of 8 pass |
| `tools/seam/seam.py` idle 10,000 connections | 32.27% of one core, against 32.60% in the earlier record |
| Autobahn groups 1 to 7, 9, 10 over HTTP/1.1 | 291 OK, 7 NON-STRICT, 3 INFORMATIONAL, no failure; the same cases as in the first run |
| `ws_h2_client.py` over HTTP/2 | 32 of 32 checks |
| `sse_check.sh` | 1000 events in order on HTTP/1.1 and on HTTP/2; the replay after `Last-Event-ID` 990 gives 10 events, after 400 gives 600 events |
| `tools/abuse/ws_abuse.py` | 9 of 9 pass |

The WebSocket abuse checks cover a Ping flood (Close 1008), a flood of text frames of one
octet (Close 1008), a message that never ends (Close 1009 at the limit of 1 MiB), a client
that sends 2 MiB of echoes and reads nothing, 2,000 handshakes that are never read and 500
half-open upgrades. After each check a new connection gets an ordinary answer within two
seconds. The abuse check of a slow reader of an event stream has a unit test (the stall
rule) and no live run.

The load run used `tools/validate/ws_sse_load.py` against `ws_echo load` and `sse_replay`,
both on HTTP/1.1, with 6,000 idle WebSocket sessions and 6,000 open event streams held
together, and 50 ordinary requests per second for 20 seconds:

| Measure | Value |
| --- | --- |
| memory per WebSocket session | about 10.4 KB |
| memory per event stream | about 5.8 KB |
| ordinary requests | 1,000 sent, 0 failed, p50 0.5 ms, p99 3.3 ms, maximum 5.8 ms |
| CPU of the WebSocket server | 18.8% of one core |
| CPU of the event-stream server | 25.9% of one core |
| time of `Stop` with all sessions open | 7.5 s for both servers |

The plan asked for 10,000 sessions and 10,000 streams at once. The loopback interface of
the host offers about 16,000 client ports, so the run holds 12,000 connections. The idle CPU
follows the O(n) `poll` of macOS that the seam record names. A burst of 100 upgrades that
arrive together passes the admission queue only in part: the server answers the rest with
503 and `Retry-After`, and the load client tries again.

The sessions of the load client never answer the Close frame, so the stop time of 7.5 s
includes the close timeout of 5 s.


The script `tools/validate/ws_h2_client.py` also holds the full case list. Against
`examples/ws_echo big` on 2026-10-22 it passed 32 of 32 checks: the echo of text and
binary messages of 0, 1, 125, 126, 65535, 65536 octets and 4 MiB, a fragmented message,
a Ping with its Pong, a close with each of the codes 1000, 1001, 1007, 1011, 3000 and
4999, the forced protocol errors (a reserved bit, an unmasked frame, bad UTF-8, a control
frame over 125 octets, a fragmented control frame, an unknown opcode, a message of 33 MiB
against the limit of 32 MiB), and 180 concurrent streams on one connection.

The browser check over HTTP/2 did not run. Chrome uses HTTP/2 only over TLS, and the
test certificate of the repository is self-signed, so Chrome stops at a certificate
page. The record of Chrome over HTTP/1.1 above and the `h2`/`wsproto` run above prove
the two paths separately.

The handler pool holds an interface reference of the request and the response object
across each handler call, so a handler that takes an interface of its own, for example
with `Supports`, does not destroy the object.

The server reuses the object of a closed connection for a later connection. A loop that
starts a server, opens a connection with `openssl s_client`, makes an HTTP/1.1 request
and then an HTTP/2 request, while eight processes keep the CPU busy, ran 40 times with
no hang. The script `tools/validate/run.sh` ran 8 times under the same load with no
failure. The curl calls of the script have a time limit of 10 seconds, so a failure
reports FAIL and does not wait.

Gaps of this record: the Autobahn run covers HTTP/1.1 only, and a WebSocket in a
browser over HTTP/2 has no record.

### Server-sent events

The unit tests assert the exact bytes of the encoder for the rules of the WHATWG
HTML Living Standard section 9.2 (checked on 2026-10-22): the line splitting at
LF, CR and CRLF, the final empty data field, the two spaces after the colon for
a value that starts with a space, the rejection of CR, LF and NUL, the rejection
of text that is not UTF-8 and the `retry` cap. The stream tests use a fake
channel and a real streaming pool of one thread. They show that two producer
threads write 1000 whole events with no interleave, that a keep-alive comment
reaches an idle stream, that an event stream with a steady flow gets no comment,
that a stalled stream is closed with an abort and a drained stream is not, and
that 1000 open streams with a period of 40 milliseconds are served by one pool
thread.

Three live tests run on a server over HTTP/2: the events arrive byte for byte,
an idle stream receives the keep-alive comment, and `Stop` ends a stream with
END_STREAM. The example `examples/sse_clock.pas` shows the events with
`curl --http2-prior-knowledge -N` on 2026-10-22: the status is 200, the content
type is `text/event-stream`, and one `tick` event arrives each second.

Gaps of this record: the run with 5000 open streams and one ordinary request is
not made, and a browser `EventSource` is not checked. The event stream runs on
HTTP/1.1 too (see the section on the HTTP/1.1 fallback).

### The connection seam

The command `python3 tools/seam/seam.py` drives a running example server and
measures the connection seam of the server: many idle connections, many
streams at once, and a handler that writes after a delay. The tool
`tools/seam/poll_cost.py` is the control: it holds the same number of idle
sockets with no HTTP/2 code and measures the cost of the platform call alone.
Every run below is a run on the development host, macOS aarch64 with FPC
3.2.4, against `bin/interop_server` with 4 IO threads and 4 handler threads.
The file descriptor limit is 60000.

The cost of an idle connection:

| Idle connections | Server CPU |
|---|---|
| 100 | 1.00% |
| 1000 | 3.80% |
| 10000 | 32.60% |

The cost is linear in the connection count, and the control names the cause:
`poll_cost.py` holds 10000 idle sockets and reports 12.76% of one core, so the
O(n) `poll` of the platform is about 40% of the server cost and the
per-round work of the event loop is the rest. macOS has no `epoll`, so a
Linux host is expected to show a cost near zero. The cost comes from the
platform call for each idle connection, and it is not a busy loop.

The answers of 500 streams on 500 connections:

| Streams | Throughput | Latency p50 | p90 | p99 | max |
|---|---|---|---|---|---|
| 500 | 4529 streams/s | 4.1 ms | 18.7 ms | 21.6 ms | 22.1 ms |

Every stream was answered, and the server used 54.4% of one core.

The write after a delay: the handler of `/slow?ms=N` sleeps, and the
connection is quiet after the request, so a response can arrive only when the
wait ends and the write wakes the event loop. The run `delayed 8 600` reports
answers between 616 ms and 1226 ms for a delay of 600 ms. Every delayed
answer arrived from the timer.

The server is not modified for these runs. The tool raises its own file
descriptor limit and starts no server.

A second set of runs compares the server before and after the detached-stream
work (the split of the connection core, the streaming pool, the channel and the
loss-of-socket cancel). Each run used a fresh server, on the same host and in the
same session (2026-10-22):

| Run | Before | After |
|---|---|---|
| 1000 idle connections, idle CPU | 8.19% | 3.80% |
| 10000 idle connections, idle CPU | 30.79% | 31.58% |
| 500 streams on 500 connections, throughput | 9442 streams/s | 9021 streams/s |
| the same run, latency p50 / p99 | 2.0 ms / 6.4 ms | 2.0 ms / 8.6 ms |

The idle run of 1000 connections varies with the host load of the moment; the
10000-connection and the throughput runs agree within the noise of one run. The
full `h2spec` package `http2` and the short runs pass before and after.

One observation is outside that comparison. A run that holds the three seam
modes one after another on a single server, with the 10000-connection idle step
first, stopped that step at 9323 connections (`Connection reset by peer`), and
the next step answered 34 of 500 streams in 120 seconds. A fresh server for each
mode does not show it. The behaviour predates the detached-stream work and
needs its own investigation.

## The memory of a long-lived connection

A leak of one `TServerStream` for each closed stream was present and is
fixed (commit `1fc8d5a`). The measurement drives one connection with
`h2load -n 1000000 -c 1 -m 1` and reads the resident memory of the process
`interop_server` itself, not the shell that holds its standard input open.

| State | Resident memory after 1,000,000 streams |
|---|---|
| Before the fix | 6896 KB to 774496 KB |
| After the fix | 6928 KB to 7968 KB |

The unit test `TConnectionCoreTest.TestClosedStreamsAreFreed` holds the same
rule without a socket: it opens and resets 2000 streams and fails when the
heap grows by one stream for each cycle.

The measurement that fixed the `WINDOW_UPDATE` bucket came from the interop
run of commit `9eda1e0`: a body of 100 MB drew 6102 `WINDOW_UPDATE` frames at
a steady rate of 2450 frames a second on a healthy connection. The unit test
`TFactoryTest.TestDefaultBuckets` holds the default capacity of 10000 and the
refill of 4000 a second, and `TAbuseLimitTest.TestWindowUpdateFloodGoAway`
holds the trip of a flood. The seam measurements above set the IO thread
count. The queue depth comes from the same run: a client that carried 50
streams at once saw every stream answered with a queue depth of 64. The
remaining defaults are the chosen protocol and operational bounds, and the
unit tests of `test/Http2Server.Config.Test.pas` hold them.

## Reference implementation comparison

Two C implementations and one FreePascal implementation act as references:
`nghttp2` (`nghttp2_v2` and `nghttp2_asio`), and the `wchttpserver`
implementation with its `commonutils` support library. The table below
records the rule, the reference behaviour, and the behaviour of this server.
| Rule | Reference | This server |
|---|---|---|
| A frame larger than `SETTINGS_MAX_FRAME_SIZE` | `nghttp2_conn.c:1762` rejects the frame with `NGHTTP2_ERR_FRAME_SIZE`. | `TServerConnectionCore.Feed` calls `FailConnection(..., ecFrameSizeError)` before the payload is buffered. |
| An uppercase header field name | `nghttp2_http.c:688` `nghttp2_check_header_name` rejects the name through `VALID_HD_NAME_CHARS[*name] != 1`, and `nghttp2_http.c:555` treats the result `-1` as a name that is not lower case. | `src/Http2Server.RequestValidation.pas` accepts a name only when it is a lowercase RFC 9110 section 5.6.2 token. |
| An unknown or empty pseudo-header, or a repeated pseudo-header | `nghttp2_http.c:97` `check_pseudo_header` reports `NGHTTP2_ERR_MALFORMED_HTTP_HEADER`. | `TRequestVerdict` is invalid; the server sends `RST_STREAM` with `PROTOCOL_ERROR`. |
| A pseudo-header after a regular field, or a pseudo-header in a trailer | `nghttp2_http.c:538` and `:550` set `NGHTTP2_HTTP_FLAG_PSEUDO_HEADER_DISALLOWED`; `nghttp2_http.c:546` then reports `NGHTTP2_ERR_MALFORMED_HTTP_HEADER`. | `ValidateRequestHeaders` reports an invalid block for a pseudo-header after a regular field and for a pseudo-header in a trailer. |
| A forbidden connection header, or `te` with a value other than `trailers` | `nghttp2_http.c:411-420` `http_request_on_header` reports `NGHTTP2_ERR_MALFORMED_HTTP_HEADER`. | `ValidateRequestHeaders` rejects `connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`, and a `te` value other than `trailers`. |
| A malformed request | `nghttp2` treats the fault as a stream error. | `ValidateRequestBlock` sends `RST_STREAM` with `PROTOCOL_ERROR` and keeps the connection open. |
| A body that differs from `content-length` | `nghttp2` reports `NGHTTP2_ERR_HTTP_HEADER` and ends the stream. | `TServerStream.CountReceivedBody` and `DeclaredLengthMatches` report the fault; the server sends `RST_STREAM` with `PROTOCOL_ERROR`. |
| A `PRIORITY` frame of the wrong length, or on stream zero | `nghttp2` reports `NGHTTP2_ERR_FRAME_SIZE` or `NGHTTP2_ERR_PROTO`. | `ProcessPriority` reports `ecFrameSizeError` for a length other than 5 and `ecProtocolError` for stream zero. |
| A `PRIORITY` frame that names its own stream as a dependency | `nghttp2_session.c` reports `NGHTTP2_ERR_PROTOCOL_ERROR`. | `ProcessPriority` and `ProcessHeaders` send `RST_STREAM` with `PROTOCOL_ERROR`. |
| A frame of another type inside a header block | `nghttp2_conn.c` reports `NGHTTP2_ERR_PROTO`. | `ProcessFrame` calls `FailConnection(..., ecProtocolError)` for any frame apart from `CONTINUATION` while a header block is open. |
| A `SETTINGS` frame with the `ACK` flag and a payload | `nghttp2` reports `NGHTTP2_ERR_FRAME_SIZE`. | `ProcessSettings` calls `FailConnection(..., ecFrameSizeError)`. |
| A stream `WINDOW_UPDATE` that raises the window above 2^31-1 | `nghttp2` reports `NGHTTP2_ERR_FLOW_CONTROL`. | `ProcessWindowUpdate` catches the flow-control fault and sends `RST_STREAM` with `FLOW_CONTROL_ERROR`. |
| A `DATA` frame on an idle stream | `nghttp2_conn.c` reports `NGHTTP2_ERR_PROTO` and the connection ends. | `ProcessData` calls `FailConnection(..., ecProtocolError)` for an idle stream and `FailConnection(..., ecStreamClosed)` for a closed stream. |

The `wchttpserver` implementation splits one write into frames of
`SETTINGS_MAX_FRAME_SIZE` or less (`TWCHTTP2SerializeStream.Write`,
`src/wchttp2con.pas:1367-1416`). It clamps the frame size to the minimum of
`HTTP2_MIN_MAX_FRAME_SIZE` when the send window is small. This server
follows the same rule in `src/Http2Server.Output.pas`: one chunk is a frame
of no more than `MaxFrameSize` bytes, and the send window bounds the chunk.
The split rule is the same in both implementations.

## Recorded gaps

Two checks do not run. Each entry holds the reason and the
condition that closes the gap.

| Gap | Reason | Condition that closes the gap |
|---|---|---|
| A 10,000-connection seam test on Linux | No Linux amd64 host is present, and FPC 3.2.4 is not installable on one: no current Debian or Ubuntu suite publishes it (`debian:sid` offers `3.2.2+dfsg-51`, and Launchpad reports the same newest version), and every upstream tarball for `x86_64-linux` answers with HTTP 403 or 404. The host of the development is macOS aarch64, which uses `poll` instead of `epoll`. The cost of `poll` at 10,000 connections is not the cost of `epoll`. The `--platform linux/amd64` emulation of Docker does run, but no FPC 3.2.4 exists for it. | A Linux amd64 host with `fpc 3.2.4` and OpenSSL 3. The file [toolchain](toolchain.md) records the Linux settings. |
| A `h2spec` run on Linux | The same reason as the row above. | The same condition as the row above. |

The limit `ulimit -n` is 1048575 on the development host, and the seam run
below that limit with 60000. The absence of a Linux host is the reason for
the gap, not the file descriptor limit.

## TLS and ALPN

The tools above drive the server over clear text HTTP/2, which RFC 9113
section 3.2 calls `h2c` with prior knowledge. The TLS layer is a separate
seam: `src/Http2Server.Tls.pas` and the `INetTls` extension of mORMot2. The
example server takes `--cert=FILE` and `--key=FILE`, which turn the listener
into TLS, and the port line then names `h2` instead of `h2c`.

Two independent clients confirm the handshake and the protocol:

| Client | Command | Result |
|---|---|---|
| OpenSSL | `openssl s_client -connect 127.0.0.1:PORT -alpn h2` | `Protocol: TLSv1.3`, `Cipher: TLS_CHACHA20_POLY1305_SHA256`, `ALPN protocol: h2`, verify code 18 (self-signed certificate) |
| The sibling client | `/tmp/h2p/h2probe --url=https://127.0.0.1:PORT/ --insecure` | `RESULT=success status=200 bytes=37`, exit 0 |

The probe is `test/h2probe.pas` of the sibling repository `../http2client`,
compiled against the certificate that the sibling repository generates. The
probe succeeds only over a negotiated `h2`: it offers `http/1.1` as the
other ALPN value and reports a failure on that answer. So one client of a
second repository, in a separate process, drove this server over TLS with
ALPN `h2`, and the two implementations of the same protocol family agree.

The sibling example `bin/basic_get` needs a certificate authority for the
self-signed certificate and holds no switch for one, which is why the probe
takes the place of the example here.