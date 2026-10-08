{**
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
}

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

The unit suite adds 309 tests with 0 errors and 0 failures. The suite holds
the local rules; the tools above hold the external rules.

### The bound on the streams in flight

The server admits `HandlerThreads + Queue.Depth` requests at once: the handler
threads serve them, and the queue holds the rest. The example server uses
4 handler threads and the default queue depth of 64, so the bound is **68**.
A client that keeps more streams in flight reaches the bound, and the server
refuses the excess with `REFUSED_STREAM`, which RFC 9113 section 8.7 permits.

The load run of the table keeps 60 streams in flight, so it stays inside the
bound and a refusal is a defect there. The same client with 100 streams
(`-n 200 -c 10 -m 10`) fails a varying count of requests (0, 10 and 34 failed
in three runs) because 100 is above 68. The large run
`h2load -n 5000 -c 50 -m 10` keeps 500 in flight and reports 2067 of the 5000
requests as failed for the same reason. The run `h2load -n 5000 -c 50 -m 1`
keeps 50 in flight and reports 5000 of 5000 requests answered, 0 failed, in
0.16 s.

A `h2load` run of many requests holds the connection open until the idle
timeout of 60 seconds in one earlier measurement, so the wall time of that
run held the timeout. The runs above finish in under one second, so the
earlier behaviour came from the client build at that time. `h2load` is a
benchmark and not a conformance tool, so no `h2load` wall time gates the
acceptance.

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
| A 10,000-connection seam test on Linux | No Linux amd64 host is present, and FPC 3.2.4 is not installable on one: no current Debian or Ubuntu suite publishes it (`debian:sid` offers `3.2.2+dfsg-51`, and Launchpad reports the same newest version), and every upstream tarball for `x86_64-linux` answers with HTTP 403 or 404. The host of the development is macOS aarch64, which uses `poll` instead of `epoll`. The cost of `poll` at 10,000 connections is not the cost of `epoll`. The `--platform linux/amd64` emulation of Docker does run, but no FPC 3.2.4 exists for it. | A Linux amd64 host with `fpc 3.2.4` and OpenSSL 3. The file `doc/verification/toolchain.md` records the Linux settings. |
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