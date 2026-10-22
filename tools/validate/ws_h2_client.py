#!/usr/bin/env python3
"""WebSocket client over HTTP/2 (RFC 8441) built from h2 and wsproto.

h2 opens the extended CONNECT streams and carries the WebSocket octets in DATA
frames. wsproto parses the frames that the server sends. The script builds the
frames that it sends by hand, so that it can break the rules on purpose.

The checks, each on its own stream:
  - echo of text and binary messages of 0, 1, 125, 126, 65535, 65536 octets and 4 MiB
  - a fragmented message, and a ping with its pong
  - a close with each valid code
  - the protocol errors a client can force: reserved bit, unmasked frame, bad UTF-8,
    a message over the limit
  - 180 concurrent streams on one connection

Usage: ws_h2_client.py HOST PORT [COUNT]
The server is `examples/ws_echo` started with the argument `big`. COUNT is the
number of messages of the first quick check (default 20). The exit code is 0 when
every check passed.
"""
import os
import socket
import struct
import sys

import h2.config
import h2.connection
import h2.events
import h2.settings
from wsproto.frame_protocol import FrameProtocol, Opcode

MASK = b"\x01\x02\x03\x04"


def mk(opcode: int, payload: bytes = b"", fin: bool = True, mask: bool = True, rsv: int = 0) -> bytes:
    """Build one WebSocket frame."""
    head = bytes([(0x80 if fin else 0) | (rsv << 4) | opcode])
    n = len(payload)
    flag = 0x80 if mask else 0
    if n < 126:
        head += bytes([flag | n])
    elif n < 65536:
        head += bytes([flag | 126]) + struct.pack(">H", n)
    else:
        head += bytes([flag | 127]) + struct.pack(">Q", n)
    if mask:
        key = MASK
        body = bytes(b ^ key[i % 4] for i, b in enumerate(payload)) if n < 4096 else _mask_big(payload)
        return head + key + body
    return head + payload


def _mask_big(payload: bytes) -> bytes:
    """Mask a large payload quickly with an integer xor."""
    n = len(payload)
    key = (MASK * ((n // 4) + 1))[:n]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(key, "big")).to_bytes(n, "big")


class Stream:
    def __init__(self, sid: int):
        self.sid = sid
        self.status = None
        self.protocol = None
        self.ws = FrameProtocol(client=True, extensions=[])
        self.messages = []          # (opcode, payload) in order, text and binary
        self.pongs = []
        self.close = None           # (code, reason) from the server
        self.ended = False
        self.reset = False
        self._partial = None

    def feed(self, data: bytes) -> None:
        self.ws.receive_bytes(data)
        for f in self.ws.received_frames():
            if f.opcode in (Opcode.TEXT, Opcode.BINARY, Opcode.CONTINUATION):
                chunk = f.payload.encode() if isinstance(f.payload, str) else bytes(f.payload)
                if self._partial is None:
                    self._partial = (f.opcode, b"")
                self._partial = (self._partial[0], self._partial[1] + chunk)
                if f.message_finished:
                    self.messages.append(self._partial)
                    self._partial = None
            elif f.opcode == Opcode.PONG:
                self.pongs.append(bytes(f.payload))
            elif f.opcode == Opcode.CLOSE:
                self.close = f.payload


class Client:
    def __init__(self, host: str, port: int):
        self.host, self.port = host, port
        self.sock = socket.create_connection((host, port), timeout=20)
        self.conn = h2.connection.H2Connection(
            config=h2.config.H2Configuration(client_side=True, header_encoding="utf-8")
        )
        self.conn.initiate_connection()
        self.conn.update_settings({h2.settings.SettingCodes.INITIAL_WINDOW_SIZE: 1 << 24})
        self.conn.increment_flow_control_window((1 << 24) - 65535)
        self.streams = {}
        self.flush()
        self.connect_enabled = False
        while not self.connect_enabled:
            self.pump()

    def flush(self) -> None:
        out = self.conn.data_to_send()
        if out:
            self.sock.sendall(out)

    def pump(self) -> None:
        data = self.sock.recv(1 << 20)
        if not data:
            raise ConnectionError("the server closed the connection")
        for ev in self.conn.receive_data(data):
            if isinstance(ev, h2.events.RemoteSettingsChanged):
                ch = ev.changed_settings.get(8)
                if ch is not None and ch.new_value == 1:
                    self.connect_enabled = True
            elif isinstance(ev, h2.events.ResponseReceived):
                s = self.streams[ev.stream_id]
                hd = dict(ev.headers)
                s.status = hd.get(":status")
                s.protocol = hd.get("sec-websocket-protocol")
            elif isinstance(ev, h2.events.DataReceived):
                self.conn.acknowledge_received_data(ev.flow_controlled_length, ev.stream_id)
                self.streams[ev.stream_id].feed(ev.data)
            elif isinstance(ev, h2.events.StreamEnded):
                self.streams[ev.stream_id].ended = True
            elif isinstance(ev, h2.events.StreamReset):
                self.streams[ev.stream_id].reset = True
        self.flush()

    def open(self, extra=None) -> Stream:
        sid = self.conn.get_next_available_stream_id()
        s = Stream(sid)
        self.streams[sid] = s
        hdr = [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "http"),
               (":path", "/ws"), (":authority", f"{self.host}:{self.port}"),
               ("sec-websocket-version", "13"), ("sec-websocket-protocol", "echo")]
        self.conn.send_headers(sid, hdr + (extra or []))
        self.flush()
        while s.status is None and not s.reset:
            self.pump()
        return s

    def send(self, s: Stream, data: bytes, end: bool = False) -> None:
        view = memoryview(data)
        while len(view) > 0:
            if s.reset or s.ended or s.close is not None:
                return      # the server has answered; the rest of the data is moot
            room = min(self.conn.local_flow_control_window(s.sid), self.conn.max_outbound_frame_size)
            if room <= 0:
                self.pump()
                continue
            chunk = bytes(view[:room])
            view = view[room:]
            self.conn.send_data(s.sid, chunk, end_stream=end and len(view) == 0)
            self.flush()
        if end and len(data) == 0:
            self.conn.end_stream(s.sid)
            self.flush()

    def wait(self, cond, what: str):
        for _ in range(20000):
            if cond():
                return
            self.pump()
        raise TimeoutError(what)


results = []


def record(name: str, ok: bool, detail: str = "") -> None:
    results.append(ok)
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))


def check_sizes(c: Client) -> None:
    for size in (0, 1, 125, 126, 65535, 65536, 4 * 1024 * 1024):
        for text in (True, False):
            s = c.open()
            body = (b"a" * size) if text else os.urandom(size)
            c.send(s, mk(1 if text else 2, body))
            c.wait(lambda: len(s.messages) >= 1 or s.reset, f"echo {size}")
            got = s.messages[0] if s.messages else (None, None)
            payload = got[1]
            record(f"echo {'text' if text else 'binary'} {size}", payload == body)
            c.send(s, mk(8, struct.pack(">H", 1000)))
            c.wait(lambda: s.close is not None or s.reset, "close")


def check_fragments_and_ping(c: Client) -> None:
    s = c.open()
    c.send(s, mk(1, b"frag", fin=False) + mk(9, b"ping!") + mk(0, b"ment", fin=False) + mk(0, b"ed"))
    c.wait(lambda: s.messages and s.pongs, "fragments")
    record("fragmented message", s.messages[0][1] == b"fragmented")
    record("ping answered with pong", s.pongs == [b"ping!"])


def check_close_codes(c: Client) -> None:
    for code in (1000, 1001, 1007, 1011, 3000, 4999):
        s = c.open()
        c.send(s, mk(8, struct.pack(">H", code) + b"x"))
        c.wait(lambda: s.close is not None or s.reset, "close")
        got = s.close[0] if s.close else None
        record(f"close {code}", got == code, f"got {got}")


def check_errors(c: Client) -> None:
    cases = [
        ("reserved bit", mk(1, b"x", rsv=4), 1002),
        ("unmasked frame", mk(1, b"x", mask=False), 1002),
        ("bad UTF-8", mk(1, b"\xff\xfe"), 1007),
        ("control frame over 125", mk(9, b"a" * 126), 1002),
        ("fragmented control frame", mk(9, b"a", fin=False), 1002),
        ("unknown opcode", mk(3, b"x"), 1002),
        ("message over the limit", mk(2, b"z" * (33 * 1024 * 1024)), 1009),
    ]
    for name, frame, want in cases:
        s = c.open()
        c.send(s, frame)
        c.wait(lambda: s.close is not None or s.reset, name)
        got = s.close[0] if s.close else None
        record(f"protocol error: {name}", got == want, f"got {got}")


def check_concurrent(c: Client, n: int = 180) -> None:
    streams = []
    for i in range(n):
        s = c.open()
        streams.append(s)
        c.send(s, mk(1, f"m{i}".encode()))
    c.wait(lambda: all(len(s.messages) >= 1 for s in streams), "concurrent echoes")
    ok = all(s.messages[0][1]
             == f"m{i}".encode() for i, s in enumerate(streams))
    record(f"{n} concurrent streams echo", ok)
    for s in streams:
        c.send(s, mk(8, struct.pack(">H", 1000)))
    c.wait(lambda: all(s.close is not None or s.reset for s in streams), "close all")


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    c = Client(host, port)
    record("server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL", c.connect_enabled)
    s = c.open()
    record("handshake answers 200 with the subprotocol", s.status == "200" and s.protocol == "echo",
           f"status {s.status} protocol {s.protocol}")
    c.send(s, mk(8, struct.pack(">H", 1000)))
    c.wait(lambda: s.close is not None, "first close")
    check_sizes(c)
    check_fragments_and_ping(c)
    check_close_codes(c)
    check_errors(c)
    check_concurrent(c)
    print(f"{sum(results)} of {len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
