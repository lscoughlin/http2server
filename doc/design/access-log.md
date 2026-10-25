---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: access log, common log format, principal, basic auth, writer
notes:
  - The access log gives one structured record for each request to an
    IAccessLogWriter. The default factory has no writer, so the server writes
    no log.
  - The principal is a property of the request. Code that authenticates a
    request sets it. A Basic credential is the fallback.
scope: The access log record, the writer contract, the principal, the Common Log Format text and the moment of the record.
primary_types:
  - TAccessLogRecord
  - IAccessLogWriter
  - TStdOutAccessLogWriter
  - IServerRequest
db_tables: None.
related_docs:
  - doc/design/configuration.md
  - doc/design/public-api.md
  - doc/design/threading.md
  - doc/references/rfc7617.txt
invariants:
  - A nil writer adds no wrapper to the handler and costs nothing per request.
  - The writer runs on a handler-pool thread and never on an IO thread.
  - An exception of the writer never reaches the pool thread and never hides an
    exception of the handler.
  - The log never holds a password.
---
# The access log

The access log gives one record to a writer for each request that a handler
ran. The factory holds the writer. The factory default is no writer, so a
server that the caller builds without `WithAccessLogWriter` writes no log.

## The writer

`IAccessLogWriter` (`src/Http2Server.AccessLog.pas`) has one method,
`Write(const ARecord: TAccessLogRecord)`. A caller replaces the writer at
start-up with `WithAccessLogWriter` on the factory. A writer can send the record
to a file, to a queue or to a log service.

Many handler threads call `Write` at the same time. A writer guards its own
state. A slow `Write` slows the handler threads, so a writer that does slow work
queues the record and returns.

`TStdOutAccessLogWriter` is the writer that ships with the library. It formats
each record as a Common Log Format line and prints the line to standard output.
It takes one lock for each line, so the lines of two threads never mix.

## The record

`TAccessLogRecord` holds these fields.

| Field | Meaning |
|---|---|
| `RemoteAddress` | the address of the peer; an empty text when unknown |
| `Principal` | the authenticated principal; an empty text when none |
| `StartTime`, `UtcOffsetMinutes` | the start of the handler in local time, and the offset of that time from UTC in minutes, east positive |
| `Method`, `Target` | the method and the request target, with the query |
| `Protocol` | `HTTP/1.0`, `HTTP/1.1` or `HTTP/2.0` |
| `Status` | the final response status; 0 when no status went out |
| `BodyOctets` | the response body octets, without chunk framing |
| `DurationMs` | the time from the start of the handler to its return |
| `StreamId` | the HTTP/2 stream id, or the ordinal of the HTTP/1.1 exchange |
| `UserAgent`, `Referer` | the request header fields of the same names |

The loopback address of IPv4 appears as `127.0.0.1`. The mORMot2 connection
reports it as an empty text, and the server restores it.

## The principal

`IServerRequest.Principal` is a read-write property of the request. Code that
authenticates the request sets it, for example a handler that validates an
OAuth2 access token and sets the subject of the token. The access log writes the
value in the user field.

When the property is empty at the end of the request, the log uses the user name
of a `Basic` `authorization` header (RFC 7617, section 2). The name is the text
before the first colon. The password is dropped and never copied. The server
does not verify the credential, so a client can claim any name. A service that
needs a verified name sets the property.

`BasicAuthUser` is the helper that reads the name. It answers an empty text for
an absent header, for another scheme and for a malformed credential.

## The moment of the record

The record of a served request is written when the handler returns, on the handler-pool thread. The
handler decorator `TAccessLoggingHandler` (`src/Http2Server.AccessLog.Handler.pas`)
wraps the handler of the factory and passes the request and the response through
unchanged.

- A handler that raises gets a record with status 500 when no status went out.
- A request that the pool refuses before the handler runs gets a record from
  `WriteRefusalRecord`. The pool writes it when the queue is full, when the queue
  wait limit passes and when the pool stops. Method, target, remote address and
  principal come from the request. `BodyOctets` is 0 and `DurationMs` is 0.
- The status of a refusal record is 503 for an HTTP/1.1 request, and for an
  HTTP/2 request when the refusal mode is `rmHttp503`. With `rmRefuseStream` the
  server sends RST_STREAM and no response, so the status is 0 and the text shows
  `-`.
- A refusal record is written on the thread that refuses. That thread is an IO
  thread when the queue is full, and a handler-pool thread when the wait limit
  passes. A slow writer slows that thread. The cost is small in the queue-full
  case: the server is already at its limit and refuses the request, so the
  refusal record is the only extra work, and a request that the server refuses
  is cheap compared to a request that the server serves.
- A request that is dropped because the peer cancelled it before the handler
  ran has no record.
- A stream that the handler detached has the status and the body octets known at
  the return of the handler. An HTTP/2 stream that a channel answers, for
  example a WebSocket session or an event stream, can have status 0.
- An HTTP/1.1 handler that returns without a response is answered with status
  500 after the record. The record then holds status 0.

## The Common Log Format text

`FormatCommonLog` answers the Apache Common Log Format line of a record:

```text
%h %l %u [%t] "%r" %>s %b
```

- `%h` is the remote address, `%l` is always `-`, and `%u` is the principal.
- `%t` is `dd/Mon/yyyy:HH:MM:SS +zzzz` with English month names.
- `%r` is the method, the target and the protocol.
- `%>s` is the status and `%b` is the body octets. A zero value appears as `-`.
- An empty value appears as `-`.
- A character outside the printable ASCII range, a double quote and a backslash
  in a field appear as `\xHH`. A space in the principal appears as `\x20`.

## References

RFC 7617, The 'Basic' HTTP Authentication Scheme, `https://www.rfc-editor.org/rfc/rfc7617`,
checked on 2026-10-23. A verbatim copy is `doc/references/rfc7617.txt`. The
Apache format is the one of `mod_log_config`.
