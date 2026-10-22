#!/usr/bin/env python3
"""WebSocket client over HTTP/2 (RFC 8441) built from h2 and wsproto.

h2 opens the extended CONNECT stream and wsproto frames the WebSocket
messages that travel in the DATA frames. The client sends N text messages and
checks that the server echoes each one, then closes with code 1000.

Usage: ws_h2_client.py HOST PORT [COUNT]
The exit code is 0 when every echo matched and the close was clean.
"""
import socket
import sys

import h2.config
import h2.connection
import h2.events
from wsproto.frame_protocol import CloseReason, FrameProtocol, Opcode


def main() -> int:
    host, port = sys.argv[1], int(sys.argv[2])
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 20

    sock = socket.create_connection((host, port), timeout=10)
    conn = h2.connection.H2Connection(
        config=h2.config.H2Configuration(client_side=True, header_encoding="utf-8")
    )
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    # wait for SETTINGS_ENABLE_CONNECT_PROTOCOL from the server (RFC 8441 section 3)
    connect_ok = False
    while not connect_ok:
        data = sock.recv(65535)
        if not data:
            print("FAIL the server closed before SETTINGS")
            return 1
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.RemoteSettingsChanged):
                connect_ok = 8 in event.changed_settings and (
                    event.changed_settings[8].new_value == 1
                )
        sock.sendall(conn.data_to_send())
    print("ok  server advertises SETTINGS_ENABLE_CONNECT_PROTOCOL")

    stream = conn.get_next_available_stream_id()
    conn.send_headers(
        stream,
        [
            (":method", "CONNECT"),
            (":protocol", "websocket"),
            (":scheme", "http"),
            (":path", "/ws"),
            (":authority", f"{host}:{port}"),
            ("sec-websocket-version", "13"),
            ("sec-websocket-protocol", "echo"),
        ],
    )
    sock.sendall(conn.data_to_send())

    ws = FrameProtocol(client=True, extensions=[])
    status = None
    echoes = []
    closed = None
    sent = 0

    def pump() -> bool:
        nonlocal status, closed
        data = sock.recv(65535)
        if not data:
            return False
        for event in conn.receive_data(data):
            if isinstance(event, h2.events.ResponseReceived):
                status = dict(event.headers).get(":status")
                print(f"ok  response status {status}, subprotocol "
                      f"{dict(event.headers).get('sec-websocket-protocol')}")
            elif isinstance(event, h2.events.DataReceived):
                conn.acknowledge_received_data(event.flow_controlled_length, stream)
                ws.receive_bytes(event.data)
                for frame in ws.received_frames():
                    if frame.opcode == Opcode.TEXT:
                        echoes.append(frame.payload)
                    elif frame.opcode == Opcode.CLOSE:
                        closed = frame.payload
            elif isinstance(event, (h2.events.StreamEnded, h2.events.StreamReset)):
                if closed is None:
                    closed = (None, "stream ended")
        sock.sendall(conn.data_to_send())
        return True

    while status is None:
        if not pump():
            print("FAIL no response")
            return 1
    if status != "200":
        print(f"FAIL status {status}")
        return 1

    for i in range(count):
        text = f"message {i}"
        conn.send_data(stream, ws.send_data(text, True) if False else
                       ws.send_data(text))
        sent += 1
    sock.sendall(conn.data_to_send())
    while len(echoes) < count and closed is None:
        if not pump():
            break
    ok = echoes == [f"message {i}" for i in range(count)]
    print(("ok  " if ok else "FAIL ") + f"{len(echoes)} of {count} echoes matched")

    conn.send_data(stream, ws.close(CloseReason.NORMAL_CLOSURE, "bye"))
    sock.sendall(conn.data_to_send())
    while closed is None:
        if not pump():
            break
    code = closed[0] if isinstance(closed, tuple) else None
    clean = code == CloseReason.NORMAL_CLOSURE
    print(("ok  " if clean else "FAIL ") + f"close code {code}")
    sock.close()
    return 0 if ok and clean else 1


if __name__ == "__main__":
    sys.exit(main())
