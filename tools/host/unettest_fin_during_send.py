#!/usr/bin/env python3
"""Send an HTTP error and FIN while UNETTEST -a has unacknowledged data.

On macOS, disable receive-buffer autotuning for the run or the kernel may
enlarge the window enough to ACK all 1200 bytes before the response:

    sudo sysctl -w net.inet.tcp.doautorcvbuf=0
    python3 tools/host/unettest_fin_during_send.py --bind 192.168.7.44
    sudo sysctl -w net.inet.tcp.doautorcvbuf=1

shutdown(SHUT_WR), rather than close(), keeps unread client data from turning
the orderly FIN into a kernel-generated RST.
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

try:
    import fcntl
    import termios

    FIONREAD = termios.FIONREAD
except (ImportError, AttributeError):  # pragma: no cover - non-BSD hosts
    fcntl = None
    FIONREAD = None


ASYNC_PAYLOAD_LEN = 1200
TCP_MSS = 536
REASONS = {
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    409: "Conflict",
    413: "Payload Too Large",
    507: "Insufficient Storage",
}


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


def unread_bytes(conn: socket.socket) -> int | None:
    if fcntl is None or FIONREAD is None:
        return None
    try:
        raw = fcntl.ioctl(conn, FIONREAD, struct.pack("I", 0))
        return struct.unpack("I", raw)[0]
    except OSError:
        return None


def serve_one(server: socket.socket, args: argparse.Namespace) -> None:
    conn, addr = server.accept()
    actual_rcvbuf = conn.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    log(f"CONN from {addr[0]}:{addr[1]} (accepted socket rcvbuf={actual_rcvbuf})")
    if actual_rcvbuf >= ASYNC_PAYLOAD_LEN:
        log("WARNING: receive window holds the whole 1200-byte payload; "
            "FIN may arrive only after SEND has succeeded")
        if actual_rcvbuf > args.rcvbuf:
            log("WARNING: requested SO_RCVBUF was enlarged; disable "
                "net.inet.tcp.doautorcvbuf on macOS")
    elif actual_rcvbuf <= TCP_MSS:
        log(f"WARNING: receive window must be larger than TCP MSS {TCP_MSS}")

    log(f"holding {args.delay}s without reading")
    time.sleep(args.delay)
    queued = unread_bytes(conn)
    if queued is not None:
        log(f"{queued} bytes queued unread at FIN time")
        if queued == 0 or queued >= ASYNC_PAYLOAD_LEN:
            log("WARNING: timing did not leave a partially acknowledged SEND")

    body = args.body.encode()
    reason = REASONS.get(args.status, "Error")
    response = (
        f"HTTP/1.1 {args.status} {reason}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode() + body
    conn.sendall(response)
    log(f"sent {len(response)}-byte response: HTTP/1.1 {args.status} {reason}")
    conn.shutdown(socket.SHUT_WR)
    log("FIN sent; socket remains open to prevent an RST")

    time.sleep(args.grace)
    conn.settimeout(args.linger)
    drained = 0
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                log("client closed its side")
                break
            drained += len(chunk)
    except socket.timeout:
        log("client still open after --linger; closing server side")
    log(f"drained {drained} bytes after FIN")
    conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bind", default="192.168.7.44")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--rcvbuf", type=int, default=700)
    parser.add_argument("--delay", type=float, default=0.6)
    parser.add_argument("--grace", type=float, default=1.0)
    parser.add_argument("--linger", type=float, default=5.0)
    parser.add_argument("--status", type=int, default=400)
    parser.add_argument("--body", default="")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args(argv)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    try:
        server.bind((args.bind, args.port))
        server.listen(1)
        log(f"READY bind={args.bind}:{args.port} requested_rcvbuf={args.rcvbuf} "
            f"delay={args.delay}s status={args.status}")
        while True:
            serve_one(server, args)
            if args.once:
                break
    except OSError as exc:
        log(f"socket error: {exc}")
        return 1
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
