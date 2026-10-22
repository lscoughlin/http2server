---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: references, rfc, specifications, websocket, http2, http11, sse
notes:
  - This file indexes the plain-text copies of the specifications.
  - The RFC texts are verbatim copies. They carry the licence and the
    copyright of the IETF Trust, not the licence of this library.
scope: The specifications that the library follows, with the retrieval date of each copy.
primary_types: []
db_tables: []
related_docs:
  - doc/README.md
---

# References

This directory holds plain-text copies of the specifications that the library
follows. A document cites an RFC by number and by its rfc-editor URL, with the
date of the check. A document can also name the copy in this directory.
The documentation rules skip the copies, because the copies are verbatim.

All copies were retrieved on 2026-10-22 from `https://www.rfc-editor.org/rfc/rfcNNNN.txt`
unless the table names another source.

## HTTP/2

| File | RFC | Title | Use |
| --- | --- | --- | --- |
| `rfc9113.txt` | 9113 | HTTP/2 | The current HTTP/2 specification. It obsoletes RFC 7540. |
| `rfc7541.txt` | 7541 | HPACK: Header Compression for HTTP/2 | The header codec. |
| `rfc9110.txt` | 9110 | HTTP Semantics | Methods, status codes and header fields for every HTTP version. |
| `rfc9218.txt` | 9218 | Extensible Prioritization Scheme for HTTP | Not implemented. Kept for reading. |
| `rfc8740.txt` | 8740 | Using TLS 1.3 with HTTP/2 | TLS policy. |

## HTTP/1.1

| File | RFC | Title | Use |
| --- | --- | --- | --- |
| `rfc9112.txt` | 9112 | HTTP/1.1 | Message framing, chunked coding, connection management. It obsoletes RFC 7230. |
| `rfc6585.txt` | 6585 | Additional HTTP Status Codes | Section 5 defines 431 Request Header Fields Too Large. |

## WebSocket

| File | RFC | Title | Use |
| --- | --- | --- | --- |
| `rfc6455.txt` | 6455 | The WebSocket Protocol | The framing, the opening handshake over HTTP/1.1, the closing handshake. |
| `rfc8441.txt` | 8441 | Bootstrapping WebSockets with HTTP/2 | The extended CONNECT method. It cites RFC 7540 section numbers. |
| `rfc7936.txt` | 7936 | Clarifying Registry Procedures for the WebSocket Subprotocol Name Registry | Subprotocol names match with case. |
| `rfc8307.txt` | 8307 | Well-Known URIs for the WebSocket Protocol | The `/.well-known/` prefix applies to `ws` and `wss`. |
| `rfc7692.txt` | 7692 | Compression Extensions for WebSocket | Deferred. The plan does not implement `permessage-deflate`. |

RFC 8441 cites RFC 7540. The matching sections of RFC 9113 are:

| RFC 7540 | RFC 9113 | Subject |
| --- | --- | --- |
| 6.5.2 | 6.5.2 | The SETTINGS parameters |
| 8.1.2.3 | 8.3.1 | The request pseudo-header fields (RFC 9113 8.3 holds the general rules) |
| 8.1.2.6 | 8.1.1 | Malformed requests and responses |
| 8.3 | 8.5 | The CONNECT method |
| 11.3 | 11 | The "HTTP/2 Settings" registry. RFC 9113 section 11 keeps the registry and does not restate it |

## Server-sent events

| File | Source | Use |
| --- | --- | --- |
| `whatwg-html-server-sent-events.txt` | `https://html.spec.whatwg.org/multipage/server-sent-events.html`, section 9.2 of the HTML Living Standard | The `text/event-stream` format, reconnection and `Last-Event-ID`. Plain text made from the HTML page. The text is a living standard, so the retrieval date matters. |

## Origin and registries

| File | Source | Use |
| --- | --- | --- |
| `rfc6454.txt` | RFC 6454, The Web Origin Concept | The origin triple, the `Origin` header grammar and the comparison rule. |
| `iana-websocket-registry.xml` | `https://www.iana.org/assignments/websocket/websocket.xml`, retrieved 2026-10-22 | The WebSocket close codes (1012 to 1014 are assigned), opcodes, version numbers and header registrations. |

## Other sources

- mORMot2, pinned at revision `b2b195da1` in `third_party/mORMot2`. The
  WebSocket units are `src/net/mormot.net.ws.*.pas`. The HTTP/1.1 parser is
  `src/net/mormot.net.http.pas`.
