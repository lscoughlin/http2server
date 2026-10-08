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
| Second implementation | `nghttp -n http://127.0.0.1:PORT/` | A body of 37 bytes and a GOAWAY frame with the code `NO_ERROR` |
| Widely deployed client | `curl --http2-prior-knowledge http://127.0.0.1:PORT/` | Status 200, 37 bytes |
| Large response | `curl --http2-prior-knowledge 'http://127.0.0.1:PORT/large?bytes=8388608'` | 8388608 bytes in 0.0168 s |
| Load | `h2load -n 200 -c 10 -m 10 http://127.0.0.1:PORT/` | 200 requests, 0 failed |

The unit suite adds 302 tests with 0 errors and 0 failures. The suite holds
the local rules; the tools above hold the external rules.

The `h2load` run with the settings `-n 5000 -c 50 -m 20` reports
`REFUSED_STREAM` for 1002 of the 5000 requests. The reason is the bounded
admission queue of 64 entries and the limit of 1000 concurrent streams. The
server refuses the excess requests with `REFUSED_STREAM`, which RFC 9113
section 8.7 permits. The small run above does not reach the limit.

A `h2load` run of many requests holds the connection open until the idle
timeout of 60 seconds, so the wall time of the run holds the timeout. The
request counts and the failure counts of the table come from such a run. A
run of the same shape against `nghttpd` of nghttp2 finishes at once. The
cause of the difference is not established, and `h2load` is a benchmark and
not a conformance tool, so the run is not part of the acceptance gate. The
remark is in the gap table below.

### The memory of a long-lived connection

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

The server measurements that fixed the default limits came from an earlier
run of 100 MiB of output over 2450 frames. The values are in
`src/Http2Server.Config.pas` and `doc/design/configuration.md`.

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

Three checks do not run. Each entry holds the reason and the
condition that closes the gap.

| Gap | Reason | Condition that closes the gap |
|---|---|---|
| A 10,000-connection seam test on Linux | No Linux amd64 host is present. The host of the development is macOS aarch64, which uses `poll` instead of `epoll`. The cost of `poll` at 10,000 connections is not the cost of `epoll`. | A Linux amd64 host with `fpc 3.2.4` and OpenSSL 3. The file `doc/verification/toolchain.md` records the Linux settings. |
| A `h2spec` run on Linux | The same reason as the row above. | The same condition as the row above. |
| The end of a long `h2load` run | The server holds the connection open until the idle timeout, so the run takes 60 seconds and reports a few requests as failed. The cause is not established. `h2load` is a benchmark, not a conformance tool, so the result does not gate the acceptance. | An analysis of the connection teardown that `h2load` starts at the end of a run. |

The limit `ulimit -n` is 1048575 on the development host, so the file
descriptor limit is not the reason for the gap. The absence of a Linux host
is the reason.

## TLS and ALPN

The tools above drive the server over clear text HTTP/2, which RFC 9113
section 3.2 calls `h2c` with prior knowledge. The TLS layer is a separate
seam: `src/Http2Server.Tls.pas` and the `INetTls` extension of mORMot2. The
validation of the TLS handshake and the ALPN result needs a certificate and
is a separate task.