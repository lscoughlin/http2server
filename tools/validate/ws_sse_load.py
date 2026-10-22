#!/usr/bin/env python3
"""Load run: idle WebSocket sessions and open event streams with steady requests.

The script starts nothing but the two clients of the load. A caller starts
`bin/ws_echo HOST WSPORT load` and `bin/sse_replay HOST SSEPORT` first, and raises
the file limit (`ulimit -n 60000`).

It opens N WebSocket sessions on the first server and N event streams on the second
(path /hold), both over HTTP/1.1 on plain sockets. Then it sends ordinary requests
at a steady rate for the window and reports the latency percentiles. It reads the
resident memory and the CPU time of both server processes before and after.

Usage: ws_sse_load.py HOST WSPORT SSEPORT N WINDOW RATE WSPID SSEPID
"""
import asyncio
import subprocess
import sys
import time

KEY = "dGhlIHNhbXBsZSBub25jZQ=="


def ps(pid: int):
    out = subprocess.run(["ps", "-o", "rss=,cputime=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.split()
    rss_kib = int(out[0])
    t = out[1]
    parts = t.replace(".", ":").split(":")
    secs = int(parts[0]) * 60 + int(parts[1]) + int(parts[2]) / 100.0 if len(parts) == 3 else 0.0
    return rss_kib, secs


async def open_ws(host, port, sem):
    async with sem:
        # a burst can pass the admission queue; the server answers 503 with Retry-After
        # and the client tries again, as the answer asks
        for _ in range(50):
            r, w = await asyncio.open_connection(host, port)
            w.write((f"GET /ws HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                     f"Connection: Upgrade\r\nSec-WebSocket-Key: {KEY}\r\n"
                     f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
            head = await r.readuntil(b"\r\n\r\n")
            if head.startswith(b"HTTP/1.1 101"):
                return (r, w)
            w.close()
            await asyncio.sleep(0.05)
        return None


async def open_sse(host, port, sem):
    async with sem:
        for _ in range(50):
            r, w = await asyncio.open_connection(host, port)
            w.write(f"GET /hold HTTP/1.1\r\nHost: {host}\r\n\r\n".encode())
            head = await r.readuntil(b"\r\n\r\n")
            if head.startswith(b"HTTP/1.1 200"):
                return (r, w)
            w.close()
            await asyncio.sleep(0.05)
        return None


async def requests(host, port, window, rate, lat):
    end = time.monotonic() + window
    interval = 1.0 / rate
    nxt = time.monotonic()
    tasks = []

    async def one():
        t0 = time.monotonic()
        try:
            r, w = await asyncio.open_connection(host, port)
            w.write(f"GET /events HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n"
                    f"Last-Event-ID: 999\r\n\r\n".encode())
            await r.read(-1)
            w.close()
            lat.append((time.monotonic() - t0) * 1000.0)
        except Exception:
            lat.append(float("inf"))

    while time.monotonic() < end:
        tasks.append(asyncio.create_task(one()))
        nxt += interval
        await asyncio.sleep(max(0.0, nxt - time.monotonic()))
    await asyncio.gather(*tasks)


async def main():
    host, wsport, sseport = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    n, window, rate = int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
    wspid, ssepid = int(sys.argv[7]), int(sys.argv[8])
    base_ws, base_sse = ps(wspid), ps(ssepid)
    sem = asyncio.Semaphore(200)
    t0 = time.monotonic()
    ws = await asyncio.gather(*[open_ws(host, wsport, sem) for _ in range(n)])
    sse = await asyncio.gather(*[open_sse(host, sseport, sem) for _ in range(n)])
    ok_ws = sum(1 for x in ws if x)
    ok_sse = sum(1 for x in sse if x)
    print(f"opened {ok_ws} WebSocket sessions and {ok_sse} event streams in {time.monotonic() - t0:.1f} s")
    await asyncio.sleep(2)
    open_ws_rss, open_sse_rss = ps(wspid), ps(ssepid)
    print(f"memory per WebSocket session: {(open_ws_rss[0] - base_ws[0]) * 1024 / max(ok_ws, 1):.0f} octets")
    print(f"memory per event stream: {(open_sse_rss[0] - base_sse[0]) * 1024 / max(ok_sse, 1):.0f} octets")
    lat = []
    c0w, c0s = ps(wspid)[1], ps(ssepid)[1]
    await requests(host, sseport, window, rate, lat)
    c1w, c1s = ps(wspid)[1], ps(ssepid)[1]
    lat.sort()
    fin = [x for x in lat if x != float("inf")]
    p = lambda q: fin[min(len(fin) - 1, int(len(fin) * q))] if fin else float("nan")
    print(f"ordinary requests: {len(lat)} sent, {len(lat) - len(fin)} failed, "
          f"p50 {p(0.5):.1f} ms, p99 {p(0.99):.1f} ms, max {fin[-1] if fin else float('nan'):.1f} ms")
    print(f"server CPU during the window: WebSocket server {(c1w - c0w) / window * 100:.1f}%, "
          f"event-stream server {(c1s - c0s) / window * 100:.1f}% of one core")
    print("READY")
    sys.stdout.flush()
    await asyncio.sleep(3600)


if __name__ == "__main__":
    asyncio.run(main())
