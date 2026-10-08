{**
---
license: LGPL-2.1-only WITH Independent-modules-exception
copyright: Copyright 2026 Liam Seamus Coughlin
keywords: http2, server, coroutines, fpc, swapcontext, exception-heads, future
notes:
  - This document holds a deferred option and the research that keeps it
    possible. No code in the library uses a coroutine.
  - The measurements come from one development host and one Linux host. The
    document names each one.
scope: The deferred coroutine option for handler code, the FPC facts it rests on, the research result and the open items.
primary_types:
  - IStreamWaiter
  - TBlockingWaiter
db_tables: []
related_docs:
  - doc/design/seam.md
  - doc/design/threading.md
  - doc/design/architecture.md
  - doc/design/fpc-runtime.md
invariants:
  - No code in the library uses a coroutine.
  - The wait of a stream goes through one interface with four members.
  - A change of the wait implementation changes no other unit.
---

# Future coroutines

The handler contract of the library is synchronous. A handler reads the
request, writes the response and returns. A handler thread blocks while a
handler waits, so one handler thread serves one request at a time.

A different design gives one handler thread many handlers. The handler code
stays synchronous, and the runtime captures the continuation when the handler
would block. Free Pascal has no `async` and no `await` and no coroutine
language feature, so a stackful coroutine is the only route to that design. A
stackful coroutine has its own stack and its own context, and a switch moves
control to another coroutine on the same thread.

The library does not use coroutines. The user deferred the design so that the
protocol work could land first. The seam keeps the option open, and this
document records the research.

## The interface that keeps the option open

Every wait of a stream goes through `IStreamWaiter`
(`src/Http2Server.Seam.pas`). The interface has four members.

```pascal
IStreamWaiter = interface
  function  Wait(const ATimeoutMs: Integer): TWaitResult;
  procedure Signal;
  procedure Cancel;
  function  IsCancelled: Boolean;
end;
```

`TBlockingWaiter` (`src/Http2Server.Waiter.pas`) implements the interface with
an `RTLEvent`. A coroutine scheduler implements the same interface with a
resume of another coroutine. The surface is small on purpose: the waiter is
the only place where a stream sleeps, so it is the only place a coroutine
scheduler must replace. The document [seam](seam.md) holds the current
implementation.

## The mechanism

The research used `getcontext`, `makecontext` and `swapcontext` from libc,
declared as `external 'c'`. The macOS SDK marks these routines as deprecated
(`usr/include/ucontext.h`), and they still link and run on the development
host. The structure offsets come from the SDK headers, not from memory:
`uc_stack.ss_sp` at 8, `uc_stack.ss_size` at 16, `uc_link` at 32 on arm64.
A first probe that guessed the offsets ended with a `SIGSEGV`; the header
offsets fixed it. A production design must bind the structure per platform
and must not guess it.

## The obstacle: the exception heads

Free Pascal keeps its active `try` frames as a linked list in two
thread-local heads: one head for the frame chain and one head for the current
exception object. A coroutine switch does not change the heads. The frames
themselves live on each coroutine stack, and only the two heads are
thread-local.

The obstacle follows. Two coroutines on one thread can pop the frame that the
other pushed, and a resume on a second thread sees that thread's list. Both
cases corrupt the list.

The two heads are not visible to user code: the identifiers
`ExceptAddrStack` and `ExceptObjectStack` do not compile, and the unit-private
symbols in the RTL object file do not link. The RTL does export two public
entry points, `fpc_pushexceptaddr` and `fpc_popaddrstack`, and the research
reached the two heads through them.

- Read the first head: push a record that the caller owns, read its `Next`
  field, then pop the record.
- Write the first head to a value: push a record, set its `Next` field to the
  value, then pop the record.
- Read the second head: the `RaiseList` routine answers it.
- Write the second head: raise a dummy exception, and set the `Next` field of
  the record inside the `except` block. The exit from the handler pops the
  record, so the head becomes the new value.

The switch routine saves the heads of the scheduler, loads the heads of the
coroutine, calls `swapcontext`, saves the heads of the coroutine, and
restores the heads of the scheduler.

One naming fact matters. On aarch64-darwin in Free Pascal 3.2.4 the external
name `fpc_popaddrstack` links without `cdecl` only; with `cdecl` the linker
looks for `_fpc_popaddrstack`.

## The probes

Six probes were built. They run on one development host, aarch64-darwin with
Free Pascal 3.2.4 and `-O2`, and on one Linux host, amd64 with glibc 2.39 and
Free Pascal 3.2.2.

| Probe | Design | aarch64-darwin | Linux amd64 |
| --- | --- | --- | --- |
| 1 | one coroutine, one thread; a yield inside and outside a `try`, and a raise that is caught after the resume | pass | not run |
| 2 | two coroutines on one thread, each inside a `try`, with a raise after each resume | fail (the process ends with status 0 and no message) | not run |
| 3 | one coroutine that enters a `try` on one thread and raises after a resume on another thread | fail (the `try` catches nothing) | not run |
| 4 | probes 2 and 3 with the first-head swap only | **pass** both cases | **pass** |
| 5 | the same with a stress load: 2000 coroutines, yields inside `try`, inside `except`, inside `finally`, nested raises | fail: one thread finishes with `bad=76090` corrupted exception objects; four threads end with exit status 217 | fail: an unhandled `EAbort` |
| 6 | probe 5 plus the second-head swap | **pass**: 2000 of 2000 coroutines, 60000 of 60000 iterations, `bad=0`, about 0.6 s wall time on four threads | **pass**, `bad=0`, 0.26 s |

Probe 5 shows that the first-head swap alone is not enough. Probe 6 shows that
the two heads together are enough, on both hosts, with migration between
threads.

Caveats: one run per cell; one coroutine in the cost benchmark; no cache
pressure from many stacks. The record layout of the exception frame was
assumed and not read from a source file; the probes work, so it matches on
both hosts.

## The cost of a switch

The benchmark runs one million resume-and-yield pairs. One pair is two
`swapcontext` calls.

| Host | raw `swapcontext` pair | `Resume` with the head swap |
| --- | --- | --- |
| aarch64-darwin, FPC 3.2.4 | 1855 ns | 1782 ns |
| Linux amd64, FPC 3.2.2 | 1225 ns | 1332 ns |

The head swap adds about 0 to 110 ns per pair and is inside the measurement
noise on the development host. `swapcontext` itself costs 0.6 to 0.9
microseconds per switch, because both glibc and macOS make a signal-mask
system call inside it. A hand-written assembly switch removes that call. It is
an optimisation, not a need.

## The options

| Option | A yield inside a `try` | Migration between threads | State |
| --- | --- | --- | --- |
| A. stackful coroutines with the two heads saved and restored on every switch | yes | yes | works on aarch64-darwin; pass on Linux amd64 with FPC 3.2.2 |
| B. stackful coroutines that each stay on one handler thread | yes, with the head swap on that thread | no | probe 2 shows that a single-thread switch still corrupts the list without the swap |
| C. coroutines with a rule: no yield inside any frame | by a ban that the compiler does not enforce | yes | managed locals make the rule hard to hold |
| D. one blocking thread per handler, the present design | not applicable | not applicable | the thread count is high |
| E. callback or state-machine handlers on a few threads | not applicable | not applicable | the thread count is low and the handler code does not look synchronous |

Probe 2 decides between A and B: any option that runs two coroutines on one
thread needs the head swap.

## Open items

1. The floor of the stack size. The probes used 128 KiB stacks. The floor that
   a real handler needs is not measured.
2. Free Pascal 3.2.4 on Linux. The Linux probe ran Free Pascal 3.2.2, because
   the 3.2.4 archive was not reachable at the time. The behaviour of 3.2.4 on
   Linux is not measured.
3. The deprecated macOS `swapcontext`. The SDK marks the routine as
   deprecated. A hand-written assembly switch is the alternative, and it is
   not written.
4. The other thread-local state that a migrating coroutine can touch. Each one
   needs a probe or a source read: the `IOResult` value, the cached `errno`
   around libc calls, the per-thread state of the Free Pascal memory manager,
   and the thread variables of mORMot2 and of a caller.
5. The exception frame layout. A production design reads the layout from the
   RTL source for each supported platform.
6. The interaction with the cancel worker pool. A cancel hook runs on its own
   thread today. A coroutine design must state whether a hook may resume a
   coroutine.

## The decision

The library keeps the blocking waiter for now. The seam, the interface
`IStreamWaiter` and the single place where a stream sleeps are the parts that
make a later change possible. A later change replaces `TBlockingWaiter` and
changes no other unit.
