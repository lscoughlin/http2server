#!/usr/bin/env python3
"""
Drive the connection seam of a running HTTP/2 server.

This script starts nothing.  A caller starts the example server first:

    ./bin/interop_server PORT

The checks measure the cost of many connections, so the caller raises the
file limit first (see the note at the top of Taskfile.yaml):

    ulimit -n 60000

Three modes are present.

  idle N WINDOW [--pid PID]
      Open N idle connections and hold them for WINDOW seconds.  When a
      process id is given, the mode reads the CPU time of that process
      before and after the window and prints the idle CPU.

  active N M [--pid PID]
      Open N connections and send M requests on each, so N*M streams are in
      flight.  The mode prints the throughput and the latency percentiles.

  delayed N DELAY_MS
      Ask for a path that the server answers after a delay, and check that
      the answer arrives without another event on the connection.

Usage:
    seam.py HOST PORT idle N WINDOW [--pid PID]
    seam.py HOST PORT active N M [--pid PID]
    seam.py HOST PORT delayed N DELAY_MS

The script exits with 1 when a check fails.
"""

import os
import resource
import select
import socket
import struct
import subprocess
import sys
import time

CLIENT_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

FT_DATA = 0x0
FT_HEADERS = 0x1
FT_SETTINGS = 0x4
FT_WINDOW_UPDATE = 0x8
FT_GOAWAY = 0x7

FF_ACK = 0x1
FF_END_STREAM = 0x1
FF_END_HEADERS = 0x4

# The checks measure the server, not flow control, so each connection opens
# with a large window.  A client that leaves the window at the 65535 default
# stops the server after about 256 answers of 256 bytes, which looks like a
# stall but is the client's own fault.
STREAM_WINDOW = 1 << 22
CONNECTION_WINDOW = 1 << 24

# the server keeps 1000 concurrent streams by default
MAX_STREAMS_PER_CONNECTION = 900

# How many connections the active mode carries at once.  The product of this
# number and the streams per connection is the number of streams that wait at
# once, and that product must stay inside the admission capacity of the
# server: its handler threads plus its queue depth.  The example server uses
# 4 handler threads and the default queue depth of 64, so 50 connections of
# 2 streams stay well inside 68.  A larger product makes the server refuse
# the excess with REFUSED_STREAM, which measures the limiter and not the
# latency.
ACTIVE_WINDOW = 50


def frame(ftype, flags, stream_id, payload=b""):
    """Build one frame; the length covers the payload only."""
    return struct.pack(">I", len(payload))[1:] + bytes(
        [ftype, flags]) + struct.pack(">I", stream_id & 0x7FFFFFFF) + payload


def hpack_literal(name, value):
    """Encode one header field with the literal-without-indexing form.

    The form adds nothing to the dynamic table, so a check needs no encoder
    state and the server needs no state beyond the request.
    """
    name = name.encode() if isinstance(name, str) else name
    value = value.encode() if isinstance(value, str) else value
    out = bytearray()
    out.append(0x00)  # 0000 0000 : literal without indexing, new name
    out.append(len(name))
    out += name
    out.append(len(value))
    out += value
    return bytes(out)


def get_request_block(path, authority):
    """The HPACK block of one GET request."""
    return (hpack_literal(":method", "GET") +
            hpack_literal(":path", path) +
            hpack_literal(":scheme", "http") +
            hpack_literal(":authority", authority))


def handshake(sock):
    """Send the preface, the SETTINGS frame and the window increase."""
    settings = struct.pack(">HI", 0x4, STREAM_WINDOW)  # INITIAL_WINDOW_SIZE
    wire = CLIENT_PREFACE + frame(FT_SETTINGS, 0, 0, settings)
    wire += frame(FT_SETTINGS, FF_ACK, 0)
    # the connection window keeps its 65535 default, so the client raises it
    wire += frame(FT_WINDOW_UPDATE, 0, 0,
                  struct.pack(">I", CONNECTION_WINDOW - 65535))
    sock.sendall(wire)


def read_cpu_seconds(pid):
    """The CPU time of a process in seconds, or None when it is unknown.

    Linux reads /proc.  macOS reads the field of `ps`.  A process that is
    gone answers None, and the caller reports the gap.
    """
    if pid is None:
        return None
    if sys.platform.startswith("linux"):
        try:
            with open("/proc/%d/stat" % pid) as handle:
                parts = handle.read().split()
            ticks = os.sysconf("SC_CLK_TCK")
            return (int(parts[13]) + int(parts[14])) / ticks
        except (OSError, IndexError, ValueError):
            return None
    try:
        out = subprocess.run(
            ["ps", "-o", "cputime=", "-p", str(pid)],
            capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None
    if not out:
        return None
    # `ps` answers [[dd-]hh:]mm:ss, and the last field can hold a fraction
    days = 0
    if "-" in out:
        day_part, out = out.split("-", 1)
        days = int(day_part)
    fields = [float(part) for part in out.split(":")]
    while len(fields) < 3:
        fields.insert(0, 0.0)
    return days * 86400 + fields[0] * 3600 + fields[1] * 60 + fields[2]


def take_frames(buf):
    """Split every complete frame off the front of `buf`.

    A frame can arrive in pieces, so the caller keeps the tail and passes it
    in again with the next read.  The answer is (frames, tail).
    """
    frames = []
    while len(buf) >= 9:
        length = int.from_bytes(buf[0:3], "big")
        if len(buf) < 9 + length:
            break
        frames.append((buf[3], buf[4],
                       int.from_bytes(buf[5:9], "big") & 0x7FFFFFFF,
                       buf[9:9 + length]))
        buf = buf[9 + length:]
    return frames, buf


def open_connections(host, port, count):
    """Open `count` connections and finish the preface on each.

    The connections carry no request, so the server holds them idle.  A
    failure part way through closes what is open and reports how many were
    made, because the file limit is the usual cause.
    """
    socks = []
    try:
        for _ in range(count):
            sock = socket.create_connection((host, port), timeout=10)
            sock.setblocking(False)
            handshake(sock)
            socks.append(sock)
    except OSError as error:
        for sock in socks:
            sock.close()
        print("FAIL  opened %d of %d connections: %s"
              % (len(socks), count, error))
        return None
    return socks


def run_idle(host, port, count, window, pid):
    """Hold `count` idle connections and report the CPU the server uses."""
    socks = open_connections(host, port, count)
    if socks is None:
        return 1
    print("PASS  opened %d idle connections" % count)
    before = read_cpu_seconds(pid)
    start = time.monotonic()
    time.sleep(window)
    elapsed = time.monotonic() - start
    after = read_cpu_seconds(pid)
    for sock in socks:
        sock.close()
    if before is None or after is None:
        print("SKIP  idle CPU: no process id, or the process is gone")
        return 0
    used = after - before
    share = 100.0 * used / elapsed
    print("      idle CPU: %.3f s of CPU in %.1f s of wall time = %.2f%%"
          % (used, elapsed, share))
    # A busy loop would hold a core, so this bound separates a wait that
    # costs money from a wait that does not.  tools/seam/poll_cost.py
    # measures the floor that the platform's poll() adds.
    if share < 50.0:
        print("PASS  idle CPU stayed below half of one core")
        return 0
    print("FAIL  idle CPU passed half of one core")
    return 1


def pump(poller, by_fd, socks, tails, latencies, sent_at, answers):
    """Read whatever is ready, and count the finished streams.

    A DATA frame that carries END_STREAM finishes one stream.  The caller
    supplies the book for each stream: `latencies` takes the elapsed time,
    and `answers` takes the count per connection.
    """
    done = 0
    # poll() answers the integer descriptor it was registered with
    for fd, _ in poller.poll(50):
        index = by_fd.get(fd, -1)
        if index < 0:
            continue
        sock = socks[index]
        try:
            chunk = sock.recv(262144)
        except (BlockingIOError, InterruptedError):
            continue
        except OSError:
            continue
        if not chunk:
            continue
        frames, tails[index] = take_frames(tails[index] + chunk)
        for ftype, flags, stream_id, payload in frames:
            if ftype == FT_DATA:
                if payload:
                    # a correct client returns the credit it consumed,
                    # otherwise the server stops after one window
                    bump = struct.pack(">I", len(payload))
                    sock.sendall(frame(FT_WINDOW_UPDATE, 0, 0, bump))
                    sock.sendall(frame(FT_WINDOW_UPDATE, 0, stream_id, bump))
                if flags & FF_END_STREAM:
                    answers[index] += 1
                    done += 1
                    key2 = (index, stream_id)
                    if key2 in sent_at:
                        latencies.append(time.monotonic() - sent_at[key2])
    return done


def run_active(host, port, count, per_connection, pid):
    """Send requests and report the throughput and the latency.

    The streams of one connection go out back to back, because the delay
    between two stream headers of one connection says more about the client
    than about the server.  A batch of `count` connections is measured at a
    time, and the next batch follows, so the number of streams that wait at
    once equals `count * per_connection`.  That number must stay inside the
    admission capacity of the server (handler threads plus queue depth),
    otherwise the server refuses the excess with REFUSED_STREAM, which is
    correct behaviour and a useless latency measurement.
    """
    if per_connection > MAX_STREAMS_PER_CONNECTION:
        print("FAIL  %d streams on one connection passes the server limit of %d"
              % (per_connection, MAX_STREAMS_PER_CONNECTION))
        return 1
    window = ACTIVE_WINDOW
    if window <= 0:
        window = count
    block = get_request_block("/binary", "127.0.0.1")
    latencies = []
    answered = 0
    totals = count * per_connection
    before = None
    start = time.monotonic()
    deadline = start + 120
    for first in range(0, count, window):
        batch = min(window, count - first)
        socks = []
        sent_at = {}
        try:
            for index in range(batch):
                sock = socket.create_connection((host, port), timeout=30)
                sock.setblocking(False)
                handshake(sock)
                wire = b""
                for stream in range(per_connection):
                    wire += frame(FT_HEADERS, FF_END_HEADERS | FF_END_STREAM,
                                  1 + stream * 2, block)
                now = time.monotonic()
                sock.sendall(wire)
                socks.append(sock)
                for stream in range(per_connection):
                    sent_at[(index, 1 + stream * 2)] = now
        except OSError as error:
            for sock in socks:
                sock.close()
            print("FAIL  the active setup stopped: %s" % error)
            return 1
        poller = select.poll()
        by_fd = {}
        tails = [b""] * batch
        answers = [0] * batch
        for index, sock in enumerate(socks):
            by_fd[sock.fileno()] = index
            poller.register(sock.fileno(), select.POLLIN)
        if before is None:
            before = read_cpu_seconds(pid)
        done = 0
        wanted = batch * per_connection
        while done < wanted and time.monotonic() < deadline:
            done += pump(poller, by_fd, socks, tails, latencies, sent_at, answers)
        answered += done
        for sock in socks:
            try:
                poller.unregister(sock.fileno())
            except (KeyError, OSError):
                pass
            sock.close()
    elapsed = time.monotonic() - start
    after = read_cpu_seconds(pid)

    if not latencies:
        print("FAIL  no response arrived")
        return 1
    latencies.sort()

    def percentile(fraction):
        index = int(len(latencies) * fraction)
        return latencies[min(index, len(latencies) - 1)]

    print("      %d of %d streams answered in %.2f s = %.0f streams/s"
          % (answered, totals, elapsed, answered / elapsed if elapsed else 0))
    print("      latency p50 %.1f ms, p90 %.1f ms, p99 %.1f ms, max %.1f ms"
          % (percentile(0.50) * 1000, percentile(0.90) * 1000,
             percentile(0.99) * 1000, latencies[-1] * 1000))
    if after is not None and before is not None:
        print("      server CPU: %.3f s for %.1f s of wall time = %.1f%%"
              % (after - before, elapsed, 100.0 * (after - before) / elapsed))
    if answered < totals:
        print("FAIL  %d streams stayed unanswered" % (totals - answered))
        return 1
    print("PASS  every stream answered")
    return 0


def run_delayed(host, port, count, delay_ms):
    """Check that a handler that writes after a delay wakes the IO thread.

    One connection carries one request.  The connection stays quiet after
    that request, so a response can arrive only when the wait ends by
    itself: no further frame starts a read on the connection.
    """
    path = "/slow?ms=%d" % delay_ms
    block = get_request_block(path, "127.0.0.1")
    socks = []
    sent_at = {}
    try:
        for index in range(count):
            sock = socket.create_connection((host, port), timeout=60)
            sock.setblocking(False)
            handshake(sock)
            now = time.monotonic()
            sock.sendall(frame(FT_HEADERS, FF_END_HEADERS | FF_END_STREAM,
                               1, block))
            socks.append(sock)
            sent_at[index] = now
    except OSError as error:
        for sock in socks:
            sock.close()
        print("FAIL  the delayed setup stopped: %s" % error)
        return 1

    poller = select.poll()
    by_fd = {}
    tails = [b""] * count
    for index, sock in enumerate(socks):
        by_fd[sock.fileno()] = index
        poller.register(sock.fileno(), select.POLLIN)

    answered = {}
    deadline = time.monotonic() + (delay_ms / 1000.0) * 4 + 10
    while len(answered) < len(socks) and time.monotonic() < deadline:
        finished = []
        for fd, _ in poller.poll(50):
            index = by_fd.get(fd, -1)
            if index < 0:
                continue
            sock = socks[index]
            try:
                chunk = sock.recv(262144)
            except (BlockingIOError, InterruptedError, OSError):
                continue
            if not chunk:
                continue
            frames, tails[index] = take_frames(tails[index] + chunk)
            for ftype, flags, _stream, _payload in frames:
                if ftype == FT_DATA and (flags & FF_END_STREAM):
                    finished.append(index)
        for index in finished:
            if index not in answered:
                answered[index] = time.monotonic() - sent_at[index]
    for sock in socks:
        try:
            poller.unregister(sock.fileno())
        except (KeyError, OSError):
            pass
        sock.close()

    if len(answered) < len(socks):
        print("FAIL  %d of %d delayed answers did not arrive"
              % (len(socks) - len(answered), len(socks)))
        return 1
    worst = max(answered.values())
    best = min(answered.values())
    expected = delay_ms / 1000.0
    print("      the delay is %d ms; the answers took %.0f ms to %.0f ms"
          % (delay_ms, best * 1000, worst * 1000))
    # the answer must come from the timer, so it arrives near the delay and
    # never only when the caller closes the connection
    if worst < expected:
        print("FAIL  an answer arrived before the delay ended")
        return 1
    if worst > expected + 2.0:
        print("FAIL  an answer took more than the delay plus two seconds")
        return 1
    print("PASS  every delayed answer arrived from the timer")
    return 0


def main(argv):
    if len(argv) < 4:
        print(__doc__)
        return 2
    host = argv[1]
    port = int(argv[2])
    mode = argv[3]
    rest = argv[4:]
    pid = None
    if "--pid" in rest:
        index = rest.index("--pid")
        pid = int(rest[index + 1])
        rest = rest[:index] + rest[index + 2:]

    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
    except (ValueError, OSError):
        print("      the file limit is %d, and cannot be raised to %d"
              % (soft, hard))

    if mode == "idle" and len(rest) == 2:
        return run_idle(host, port, int(rest[0]), float(rest[1]), pid)
    if mode == "active" and len(rest) == 2:
        return run_active(host, port, int(rest[0]), int(rest[1]), pid)
    if mode == "delayed" and len(rest) == 2:
        return run_delayed(host, port, int(rest[0]), int(rest[1]))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
