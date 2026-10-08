{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, limits, token-bucket, reset-flood, abuse
notes:
  - This document describes the token buckets that bound the work a peer may ask for.
scope: The reason for the limit, the clock, the bucket options, the bucket, the limit set and the defaults.
primary_types:
  - TTokenBucket
  - TTokenBucketOptions
  - TConnectionLimits
  - IMonotonicClock
db_tables: []
related_docs:
  - doc/design/configuration.md
  - doc/design/admission.md
  - doc/design/connection.md
invariants:
  - A bucket never holds more tokens than its capacity.
  - A bucket tripped sends GOAWAY with ENHANCE_YOUR_CALM.
  - Every bucket reads the clock through one interface.
---
}

# Per-connection abuse limits

The server limits client actions per connection with a token bucket. A
bucket holds tokens. A client action takes tokens from the bucket. An empty
bucket tells the caller that the connection must close. The caller sends
`GOAWAY` with `ENHANCE_YOUR_CALM` and closes the connection after the open
streams drain.

## Why the limit exists

Rapid Reset (CVE-2023-44487) lets a client cancel streams at a high rate. A
cancel frees the stream slot, but a handler can keep running. RFC 9113 §10.5
lists other flood techniques: tiny `WINDOW_UPDATE` increments, and `PING` and
`SETTINGS` frames that each need an answer. CERT VU#421644 covers unlimited
`CONTINUATION` frames. One bucket class bounds every one of these actions.

## The clock

A bucket refills from an `IMonotonicClock`
(`src/Http2Server.Limits.pas:40`). The interface has one method, `NowMs`,
which returns the milliseconds since an unspecified start point.

`TMonotonicClock` is the real implementation
(`src/Http2Server.Limits.pas:47`). It returns `GetTickCount64`. The value
never decreases, and it wraps only after a very long run time.

`TManualMonotonicClock` is the test implementation
(`src/Http2Server.Limits.pas:54`). Its value moves only when `Advance` or
`SetNowMs` moves it. A test controls every refill, so a test of a long idle
time needs no real wait.

## The bucket options

`TTokenBucketOptions` is a fluent record
(`src/Http2Server.Limits.pas:71`). `Create` returns a zeroed record
(`src/Http2Server.Limits.pas:195`). Each `WithX` method returns a new record
with one field changed. The fields are:

| Field | Meaning |
|---|---|
| `Capacity` | the greatest number of tokens the bucket holds |
| `RefillPerSecond` | the tokens added each second, possibly fractional |
| `CostBeforeDispatch` | the token cost of a reset before a handler runs |
| `CostAfterDispatch` | the token cost of a reset after a handler runs |

`CostBeforeDispatch` and `CostAfterDispatch` apply to the reset bucket. A
reset after dispatch costs more than a reset before it, because the handler
keeps running after the cancel. Every other bucket takes its cost from the
caller of `TryTake`.

No numeric limit is in the unit. Every limit comes from the options record.
The configuration unit holds the defaults.

## The bucket

`TTokenBucket` is a class with one method, `TryTake`
(`src/Http2Server.Limits.pas:100`). The bucket starts full. `TryTake`
refills from the clock (`src/Http2Server.Limits.pas:245`), then takes
`ACost` tokens when the bucket holds enough. The method returns `True` on a
successful take and `False` on an empty bucket.

The refill has two guards. A repeated or lower clock value adds no token, so
time never runs backwards. A long idle time cannot raise the tokens above
the capacity (`src/Http2Server.Limits.pas:264`).

The trip state is sticky. The first empty-bucket answer sets `Tripped`, and
every later `TryTake` returns `False` without a refill
(`src/Http2Server.Limits.pas:268`). The connection is closing, so no later
take can succeed.

`TTokenBucket` has no lock. The caller holds the connection lock. Every call
of one bucket runs on one thread at a time.

## The limit set

`TConnectionLimits` holds the set of buckets of one connection
(`src/Http2Server.Limits.pas:147`). The set holds the reset bucket and one
bucket for each control frame kind. `TLimitKind` names the kinds:
`lkReset`, `lkPing`, `lkSettings`, `lkEmptyData`, `lkWindowUpdate` and
`lkContinuation` (`src/Http2Server.Limits.pas:122`).

Each control kind carries its own bucket. `CreateByKind` names the options
of a kind whose legitimate rate differs from the fallback
(`src/Http2Server.Limits.pas:323`). `ControlOptionsOf` reads back the
options in force for one kind. The caller of `CreateByKind` names only the
kinds that it distinguishes, and every other kind keeps the fallback
options.

A shared bucket of one capacity does not serve these kinds. The legitimate
rates are far apart. A peer sends one `WINDOW_UPDATE` frame for each window
that it refills, so a large body needs thousands of them: a measurement of
a 100 MB body sent 6102 such frames, at a steady rate of 2450 frames in
one second (`doc/verification/validation.md`). A `CONTINUATION` frame,
by contrast, follows only a header block that already passed the frame
size. One shared bucket of the least capacity closes a healthy connection
that streams a large body.

`Charge(AKind, ACost)` sends a cost to the bucket of `AKind`
(`src/Http2Server.Limits.pas:312`). The reset bucket has two costs, so
`ChargeReset(AAfterDispatch)` selects the cost that matches the dispatch
state (`src/Http2Server.Limits.pas:326`).

The trip state of the set is sticky in the same way as the bucket. The first
empty-bucket answer sets `Tripped`, and every later `Charge` returns `False`
for every kind.

The set raises `OnTrip` once, when a bucket trips, with the kind that
tripped. The server observer receives the event and counts it. The set
holds no observer reference; the connection core assigns the event.

## The caller

The connection core owns one `TConnectionLimits` per connection. It charges
the reset bucket on each client `RST_STREAM` frame, and it charges the
control bucket on each limited control frame. A `False` answer starts the
close sequence. The observer receives the bucket trip, and then the
`GOAWAY` sent event.

## The default limits

`THttp2ServerFactory.Create` sets the default of every bucket
(`src/Http2Server.Config.pas:412`). The reset bucket holds 1000 tokens, with
a refill of 100 tokens a second, a cost of one token before dispatch and
five tokens after it (`src/Http2Server.Config.pas:412`).

The `PING`, `SETTINGS`, `empty DATA` and `CONTINUATION` buckets each hold
100 tokens, with a refill of 10 tokens a second
(`src/Http2Server.Config.pas:417`). Each of these kinds is a flood signal
with no legitimate high rate, so a small bucket is the correct default.

The `WINDOW_UPDATE` bucket holds 10000 tokens, with a refill of 4000 tokens
a second (`src/Http2Server.Config.pas:432`). The capacity admits a whole
burst of a few megabytes, and the refill rate sits above the measured
rate of 2450 frames a second with headroom. A small bucket of 100 tokens
closed a healthy connection on a body of less than two megabytes: 107
control frames arrived before the body ended.
