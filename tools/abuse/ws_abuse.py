#!/usr/bin/env python3
"""Abuse checks for WebSocket sessions over HTTP/1.1.

The script starts nothing. A caller starts `bin/ws_echo HOST PORT` with the default
limits first. Each check opens its own connections, misbehaves in one way, and then
checks two things: the server ended or limited the offender as the design says, and an
ordinary request on a new connection is still answered within two seconds.

Usage: ws_abuse.py HOST PORT
The exit code is 1 when a check fails.
"""
import socket
import struct
import sys
import time

KEY = "dGhlIHNhbXBsZSBub25jZQ=="
MASK = b"\x00\x00\x00\x00"        # a zero mask keeps the frame builder cheap


def frame(opcode, payload=b"", fin=True):
    n = len(payload)
    head = bytes([(0x80 if fin else 0) | opcode])
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + MASK + payload


def upgrade(host, port, timeout=5):
    s = socket.create_connection((host, port), timeout=timeout)
    s.sendall((f"GET /ws HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            return None, b""
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    return (s if head.startswith(b"HTTP/1.1 101") else None), rest


def close_code(data):
    """The code of the first Close frame in unmasked server output, or None."""
    i = 0
    while i + 2 <= len(data):
        op, ln = data[i] & 0x0F, data[i + 1] & 0x7F
        i += 2
        if ln == 126:
            ln = struct.unpack(">H", data[i:i + 2])[0]; i += 2
        elif ln == 127:
            ln = struct.unpack(">Q", data[i:i + 8])[0]; i += 8
        if op == 8:
            return struct.unpack(">H", data[i:i + 2])[0] if ln >= 2 else 1005
        i += ln
    return None


def drain(s, seconds):
    s.settimeout(0.5)
    end = time.time() + seconds
    data = b""
    while time.time() < end:
        try:
            d = s.recv(65536)
        except socket.timeout:
            continue
        except ConnectionError:
            break
        if not d:
            break
        data += d
    return data


def alive(host, port):
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=2)
        s.sendall(f"GET / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
        data = b""
        while True:
            d = s.recv(65536)
            if not d:
                break
            data += d
        s.close()
        return data.startswith(b"HTTP/1.1 200") and time.time() - t0 < 2.0
    except OSError:
        return False


failed = 0


def record(name, ok, detail=""):
    global failed
    failed += 0 if ok else 1
    print(("PASS  " if ok else "FAIL  ") + name + (f" ({detail})" if detail else ""))


def flood(name, host, port, build, count, want):
    s, rest = upgrade(host, port)
    if s is None:
        record(name, False, "no upgrade")
        return
    try:
        s.sendall(build() * count)
    except OSError:
        pass
    data = rest + drain(s, 4)
    code = close_code(data)
    s.close()
    record(name + f" closes with {want}", code == want, f"got {code}")
    record(name + ": the server still answers", alive(host, port))


def main():
    host, port = sys.argv[1], int(sys.argv[2])
    flood("ping flood", host, port, lambda: frame(9), 5000, 1008)
    flood("1-octet text frame flood", host, port, lambda: frame(1, b"x"), 20000, 1008)

    # a message that never ends: fragments of 1 KiB until the limit of 1 MiB
    s, rest = upgrade(host, port)
    try:
        for _ in range(3000):
            s.sendall(frame(1 if _ == 0 else 0, b"a" * 1024, fin=False))
    except OSError:
        pass
    code = close_code(rest + drain(s, 3))
    s.close()
    record("a message that never ends closes with 1009", code == 1009, f"got {code}")
    record("never-ending message: the server still answers", alive(host, port))

    # a slow reader: the client sends 2 MiB of echoes and reads nothing
    s, rest = upgrade(host, port)
    s.settimeout(1)
    sent = 0
    try:
        for _ in range(2000):
            s.sendall(frame(2, b"b" * 1000))
            sent += 1
    except OSError:
        pass
    ok = alive(host, port)
    s.close()
    record("slow reader on a session does not stall the server", ok, f"{sent} frames sent")

    # handshake flood: 2000 connections that send a request and never read
    socks = []
    for _ in range(2000):
        try:
            t = socket.create_connection((host, port), timeout=2)
            t.sendall((f"GET /ws HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Key: {KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
            socks.append(t)
        except OSError:
            break
    record("handshake flood: the server still answers", alive(host, port), f"{len(socks)} connections")
    for t in socks:
        t.close()

    # half-open upgrades: a partial request head that never ends
    half = []
    for _ in range(500):
        t = socket.create_connection((host, port), timeout=2)
        t.sendall(b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n")
        half.append(t)
    record("half-open upgrades: the server still answers", alive(host, port), f"{len(half)} connections")
    for t in half:
        t.close()
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
