#!/usr/bin/env python3
"""
Drive the abuse limits of the example server with raw HTTP/2 frames.

The script starts nothing.  It expects a server that a caller started with
the `strict` profile, so the control-frame buckets fire quickly:

    ./bin/interop_server PORT strict

Each check opens a fresh connection, sends the frames of one flood, and
asserts the answer of the server.  A check prints PASS or FAIL.  The script
exits with 1 when any check fails.

Usage: abuse.py HOST PORT
"""

import socket
import struct
import sys
import time

CLIENT_PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

# frame types (RFC 9113 section 6)
FT_DATA = 0x0
FT_HEADERS = 0x1
FT_PRIORITY = 0x2
FT_RST_STREAM = 0x3
FT_SETTINGS = 0x4
FT_PING = 0x6
FT_GOAWAY = 0x7
FT_WINDOW_UPDATE = 0x8
FT_CONTINUATION = 0x9

# frame flags
FF_ACK = 0x1
FF_END_STREAM = 0x1
FF_END_HEADERS = 0x4

# error codes (RFC 9113 section 7)
EC_PROTOCOL_ERROR = 0x1
EC_INTERNAL_ERROR = 0x2
EC_FLOW_CONTROL_ERROR = 0x3
EC_STREAM_CLOSED = 0x5
EC_FRAME_SIZE_ERROR = 0x6
EC_REFUSED_STREAM = 0x7
EC_CANCEL = 0x8
EC_COMPRESSION_ERROR = 0x9
EC_ENHANCE_YOUR_CALM = 0xB

EC_NAMES = {
    EC_PROTOCOL_ERROR: "PROTOCOL_ERROR",
    EC_INTERNAL_ERROR: "INTERNAL_ERROR",
    EC_FLOW_CONTROL_ERROR: "FLOW_CONTROL_ERROR",
    EC_STREAM_CLOSED: "STREAM_CLOSED",
    EC_FRAME_SIZE_ERROR: "FRAME_SIZE_ERROR",
    EC_REFUSED_STREAM: "REFUSED_STREAM",
    EC_CANCEL: "CANCEL",
    EC_COMPRESSION_ERROR: "COMPRESSION_ERROR",
    EC_ENHANCE_YOUR_CALM: "ENHANCE_YOUR_CALM",
}


def frame(ftype, flags, stream_id, payload=b""):
    """Build one frame; the length covers the payload only."""
    return struct.pack(">I", len(payload))[1:] + bytes(
        [ftype, flags]) + struct.pack(">I", stream_id & 0x7FFFFFFF) + payload


def hpack_literal(name, value):
    """Encode one header field with the literal-without-indexing form."""
    name = name.encode() if isinstance(name, str) else name
    value = value.encode() if isinstance(value, str) else value
    out = bytearray()
    out.append(0x00)  # 0000 0000 : literal without indexing, new name
    out.append(len(name))
    out += name
    out.append(len(value))
    out += value
    return bytes(out)


def request_block(path="/"):
    """Encode the four request pseudo-headers of a plain GET."""
    block = b""
    block += hpack_literal(":method", "GET")
    block += hpack_literal(":scheme", "http")
    block += hpack_literal(":path", path)
    block += hpack_literal(":authority", "127.0.0.1")
    return block


class Conn:
    """One clear-text TCP connection with the HTTP/2 preface."""

    def __init__(self, host, port):
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.settimeout(0.5)
        self.buf = b""
        self.sock.sendall(CLIENT_PREFACE + frame(FT_SETTINGS, 0, 0))
        self.read(1.0)

    def send(self, data):
        self.sock.sendall(data)

    def read(self, seconds):
        """Read for a bounded time; return the bytes that arrived."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return self.buf
            except OSError:
                return self.buf
            if not chunk:
                return self.buf
            self.buf += chunk
        return self.buf

    def frames(self):
        """Yield the frames of the buffer that hold a full payload."""
        i = 0
        while i + 9 <= len(self.buf):
            length = int.from_bytes(self.buf[i:i + 3], "big")
            ftype = self.buf[i + 3]
            flags = self.buf[i + 4]
            sid = int.from_bytes(self.buf[i + 5:i + 9], "big") & 0x7FFFFFFF
            if i + 9 + length > len(self.buf):
                return
            payload = self.buf[i + 9:i + 9 + length]
            yield ftype, flags, sid, payload
            i += 9 + length

    def goaway_code(self):
        for ftype, flags, sid, payload in self.frames():
            if ftype == FT_GOAWAY:
                return int.from_bytes(payload[4:8], "big")
        return None

    def rst_codes(self):
        return [int.from_bytes(p[0:4], "big")
                for ftype, flags, sid, p in self.frames()
                if ftype == FT_RST_STREAM]

    def closed(self, seconds):
        """True when the peer closed the socket inside the time."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return True
            if not chunk:
                return True
            self.buf += chunk
        return False

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


results = []


def record(name, ok, detail):
    results.append(ok)
    print("%s  %s: %s" % ("PASS" if ok else "FAIL", name, detail))


def flood_check(name, host, port, send_frames, want=EC_ENHANCE_YOUR_CALM):
    """Send one control-frame flood and require a GOAWAY with `want`."""
    c = Conn(host, port)
    try:
        c.send(b"".join(send_frames))
        c.read(2.0)
        code = c.goaway_code()
        ok = code == want
        record(name, ok, "GOAWAY %s" % EC_NAMES.get(code, code))
    finally:
        c.close()


def main():
    if len(sys.argv) < 3:
        print("usage: abuse.py HOST PORT")
        return 2
    host, port = sys.argv[1], int(sys.argv[2])

    # rapid reset: open a stream, then reset it, many times
    def rapid_reset():
        out = []
        for i in range(40):
            sid = 1 + i * 2
            out.append(frame(FT_HEADERS, FF_END_HEADERS, sid,
                             request_block("/")))
            out.append(frame(FT_RST_STREAM, 0, sid,
                             struct.pack(">I", EC_CANCEL)))
        return out

    flood_check("rapid reset", host, port, rapid_reset())

    # PING flood
    flood_check("PING flood", host, port,
                [frame(FT_PING, 0, 0, b"\x00" * 8) for _ in range(40)])

    # SETTINGS flood
    flood_check("SETTINGS flood", host, port,
                [frame(FT_SETTINGS, 0, 0) for _ in range(40)])

    # empty DATA flood on stream zero
    flood_check("empty DATA flood", host, port,
                [frame(FT_DATA, 0, 0, b"") for _ in range(40)])

    # tiny WINDOW_UPDATE flood on the connection
    flood_check("WINDOW_UPDATE flood", host, port,
                [frame(FT_WINDOW_UPDATE, 0, 0,
                       struct.pack(">I", 1)) for _ in range(40)])

    # CONTINUATION flood: one HEADERS with no END_HEADERS, then continuations
    def continuation_flood():
        out = [frame(FT_HEADERS, FF_END_HEADERS, 0, b"")]
        # the first frame is fixed up below; send many continuations
        out = [frame(FT_HEADERS, 0, 1, request_block("/"))]
        for _ in range(40):
            out.append(frame(FT_CONTINUATION, 0, 1, b"x" * 64))
        return out

    c = Conn(host, port)
    try:
        c.send(b"".join(continuation_flood()))
        c.read(2.0)
        code = c.goaway_code()
        ok = code is not None
        record("CONTINUATION flood", ok,
               "GOAWAY %s" % EC_NAMES.get(code, code))
    finally:
        c.close()

    # header list over the limit
    c = Conn(host, port)
    try:
        big = request_block("/")
        big += b"".join(hpack_literal("x-big-%d" % i, "v" * 200)
                        for i in range(80))
        c.send(frame(FT_HEADERS, FF_END_HEADERS | FF_END_STREAM, 1, big))
        c.read(2.0)
        code = c.goaway_code()
        rst = c.rst_codes()
        ok = code is not None or len(rst) > 0
        record("header list over the limit", ok,
               "GOAWAY %s, RST %s" % (
                   EC_NAMES.get(code, code),
                   [EC_NAMES.get(r, r) for r in rst]))
    finally:
        c.close()

    # slow loris: the header block arrives one byte at a time
    c = Conn(host, port)
    try:
        block = request_block("/")
        wire = frame(FT_HEADERS, FF_END_HEADERS | FF_END_STREAM, 1, block)
        # send the header only, then one byte every 300 ms
        c.send(wire[:9])
        for b in wire[9:]:
            try:
                c.send(bytes([b]))
            except OSError:
                break
            time.sleep(0.3)
            if c.closed(0.01):
                break
        ok = c.closed(3.0)
        record("slow loris header timeout", ok,
               "connection closed" if ok else "connection stayed open")
    finally:
        c.close()

    failed = len([r for r in results if not r])
    print("%d checks, %d passed, %d failed" %
          (len(results), len(results) - failed, failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())