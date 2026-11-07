# Changelog

The notable changes of the library. Each entry names the release that
holds it. Dates follow the release commits.

## [0.28.0] - 2026-11-07

### Added

- The connection lifetime limits: `MaxConnectionAgeMs` and
  `MaxStreamsPerConnection` retire a connection gracefully, with the
  `seConnectionRetired` observer event.
- The server limits: `MaxConnections`, the stream timeouts, the
  connection write timeout, the outbound frame caps and the outbound
  DATA frame size cap.
- The socket options: TCP no-delay, keep-alive, buffer sizes and
  reuse-port.
- The TLS protocol range (`MinTlsVersion`, `MaxTlsVersion`).

### Changed

- The HTTP/1.1 write stall follows `WriteTimeoutMs` (default 60000 ms)
  and no longer follows `IdleTimeoutMs`.

### Fixed

- The sweep uses one tick source. A maximum age above 0 retires at the
  setting instead of at once.
- The `third_party` checkout stays out of git.

## [0.26.0] - 2026-10-26

### Added

- Mutual TLS: client certificate modes, trust anchors, the access log
  principal, failed-handshake counters and DN escaping checks.

### Changed

- The listener binds the configured host. The ALPN policy and the
  backlog stay per server. The factory validates more ranges and the
  facade re-exports more names.

### Fixed

- HTTP/2: SETTINGS apply as a delta, flow-control windows split per
  stream and connection, every octet gets credit; HPACK sizes follow
  both peers; the stream lifecycle stays sound across refusal, reset,
  trailers and GOAWAY; `GracefulGoAway` locks, the waker signals
  outside the lock, the output queue has a cap.
- WebSocket: the IO thread stays off the send lock; queued messages
  arrive in order.
- Server lifecycle: drain on Stop, one deadline, a raising observer
  survives, a failed Start cleans up.
- HTTP/1.1: an early answer to Expect closes cleanly, the request in
  progress survives, the body time has a bound; refused upgrades keep
  their octets and resume the header scan.
- The validation gains the live ALPN run of the real `h2` handshake.

## [0.25.0] - 2026-10-22

### Fixed

- The connection state resets when mORMot2 reuses the connection
  object. The IO-pool document describes the reuse as current design.

## [0.24.0] - 2026-10-22

### Added

- Server-sent events over detached streams, with keep-alive and the
  stall rule.
- WebSocket: the frame codec, the session, upgrades over HTTP/1.1
  (RFC 6455) and streams over HTTP/2 (RFC 8441).
- The HTTP/1.1 fallback on the same listener: the parser, the guard,
  chunked channels, the stalled-writer bound.
- The `Date` field and header safety in the shared response writer.
- Validation of the realtime paths with the load and abuse runs.

## [0.18.0] - 2026-10-22

### Added

- The streaming pool and stream detach into duplex channels, wired
  into the factory, the observer and Stop.

### Changed

- The connection core splits into a base unit and frame handlers.
  The admission adapters move into their own unit. The documents use
  plain YAML front matter with the specifications in
  `doc/references/`.

## [0.17.0] - 2026-10-09

### Added

- Gzip and deflate: the server negotiates and produces compressed
  response bodies.

## [0.16.0] - 2026-10-09

### Added

- The first release: the immutable factory, token bucket limits, the
  handler seam, the connection state machine, the output path, the
  admission queue, the mORMot2 IO pool, TLS with ALPN `h2`, the server
  lifecycle with the observer and facade, the RFC 9113 rules, the
  `h2spec` and abuse validation tools, the document tree and the LGPL
  licence with the Free Pascal exception.

### Fixed

- The IO pool survives a peer socket reset. The mORMot2 revision holds
  the aarch64 lock fix. A peer GOAWAY gets an answer. A connection
  error closes the TCP connection. A refused stream sends
  `RST_STREAM`. A closed stream frees on the last release.
