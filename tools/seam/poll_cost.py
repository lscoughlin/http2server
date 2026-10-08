#!/usr/bin/env python3
"""Measure the cost of poll() on many idle sockets, with no HTTP/2 code.

This is the control for the idle-CPU measurement of the server.  It opens a
listening socket, opens N client sockets that connect to it and stay quiet,
and then calls poll() on the accepted descriptors in a loop for a window of
seconds.  The CPU time of this process is the floor that a poll-based server
pays for N idle connections.

Usage: poll_cost.py N WINDOW_SECONDS
"""

import resource
import select
import socket
import sys
import time


def cpu_seconds():
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_utime + usage.ru_stime


def main(argv):
    count = int(argv[1])
    window = float(argv[2])
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))

    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(max(128, count))
    port = listener.getsockname()[1]

    # connect and accept in step, so the listen backlog never fills
    clients = []
    accepted = []
    poller = select.poll()
    for _ in range(count):
        sock = socket.socket()
        sock.connect(("127.0.0.1", port))
        clients.append(sock)
        conn, _ = listener.accept()
        accepted.append(conn)
        poller.register(conn, select.POLLIN)

    before = cpu_seconds()
    start = time.monotonic()
    hits = 0
    while time.monotonic() - start < window:
        # a short timeout: the server answers the timer each round
        if poller.poll(50):
            hits += 1
    elapsed = time.monotonic() - start
    used = cpu_seconds() - before

    print("%d idle sockets: %.3f s of CPU in %.1f s of wall time = %.2f%%"
          % (count, used, elapsed, 100.0 * used / elapsed))
    print("(poll returned an event %d times)" % hits)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
