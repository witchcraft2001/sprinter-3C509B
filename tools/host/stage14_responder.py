#!/usr/bin/env python3
"""Host-side peers for the Stage 14 manual MAME/hardware acceptance of
UNET509B.DLL, driven through UNETTEST.EXE.

Unlike stage7..stage13_responder.py, this is not a raw-Ethernet frame
simulator: UNETTEST talks IPv4/TCP/UDP through a real MAME network backend
(or a real NIC on real hardware) to a real host TCP/IP stack, so the
simplest and most representative peer is an ordinary Python socket -- the
same approach the sprinter-rtl8019a sibling kit's tools/dev/*.py scripts use
for UNETRTL.DLL's own manual acceptance. Each mode here mirrors one
UNETTEST.EXE flag combination (see docs/UNET509B.md and
docs/STAGE14_TESTING_RU.md):

    tcp-echo       plain CONNECT/SEND/RECV exercise (no flag)
    tcp-refuse     CONNECT to a closed port -> NERR_CONNECT
    tcp-stall      -a (ASYNCSEND): shrinks its receive window and stalls
                   without reading, forcing SEND to suspend with NERR_AGAIN
    udp-echo       -u UDPPORT [SIZE]: echoes the datagram back unchanged
    dual           -2 DATAPORT HOST CTRLPORT: accepts channel 0 (control,
                   acks whatever it receives) and channel 1 (data, streams
                   a continuous wrapping 0..255 byte counter)
    listen-client  -l LISTENPORT: connects OUT to the Sprinter (reversed
                   roles -- the DLL is the listener here), twice in a row,
                   to exercise both the initial accept and CLOSE's re-arm
"""
from __future__ import annotations

import argparse
import socket
import sys
import threading
import time

# UNETTEST -a sends this many bytes (src/apps/unettest.asm ASYNC_PAYLOAD_LEN).
# A peer window at or above this size never closes, so SEND never suspends.
ASYNC_PAYLOAD_LEN = 1200
TCP_MSS = 536
# ASYNC_SLICE_MS * ASYNC_MAX_AGAIN from unettest.asm: the DLL gives up on a
# resume after this many milliseconds of total stall.
ASYNC_RESUME_BUDGET_MS = 150 * 20
# LISTEN_ACCEPT_TRIES * 2000ms from unettest.asm: how long -l waits for a peer.
LISTEN_ACCEPT_TIMEOUT_S = 15 * 2.0


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def cmd_tcp_echo(args: argparse.Namespace) -> int:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(1)
    log(f"READY tcp-echo bind={args.bind}:{args.port}")
    try:
        while True:
            conn, addr = server.accept()
            log(f"CONN from {addr[0]}:{addr[1]}")
            conn.settimeout(args.timeout)
            total = 0
            try:
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    total += len(chunk)
                    conn.sendall(chunk)
            except socket.timeout:
                log("recv timed out")
            log(f"echoed {total} bytes, closing")
            conn.close()
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


def cmd_tcp_refuse(args: argparse.Namespace) -> int:
    # A closed port (no listener at all) makes the OS answer SYN with RST,
    # which is what actually exercises CONNECT's NERR_CONNECT path -- so this
    # mode's job is just to *not* listen, and say so.
    log(f"NOT listening on {args.bind}:{args.port} -- point UNETTEST at it "
        f"to exercise CONNECT's NERR_CONNECT path (connection refused)")
    log("press Ctrl+C when the manual test step is done")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    return 0


def cmd_tcp_stall(args: argparse.Namespace) -> int:
    if args.rcvbuf <= TCP_MSS:
        log(f"WARNING: --rcvbuf ({args.rcvbuf}) is not above TCP_MSS ({TCP_MSS}); "
            f"no segment will fit and the DLL will send nothing at all")
    stall_ms = args.stall * 1000
    if stall_ms >= ASYNC_RESUME_BUDGET_MS:
        log(f"WARNING: --stall ({args.stall}s) exceeds the DLL's resume budget "
            f"({ASYNC_RESUME_BUDGET_MS} ms); SEND will fail outright instead of resuming")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, args.rcvbuf)
    server.bind((args.bind, args.port))
    server.listen(1)
    log(f"READY tcp-stall bind={args.bind}:{args.port} requested_rcvbuf={args.rcvbuf} "
        f"stall={args.stall}s")
    try:
        while True:
            conn, addr = server.accept()
            actual = conn.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
            log(f"CONN from {addr[0]}:{addr[1]} (accepted socket rcvbuf={actual})")
            if actual >= ASYNC_PAYLOAD_LEN:
                log(f"WARNING: accepted rcvbuf ({actual}) holds the whole "
                    f"{ASYNC_PAYLOAD_LEN}-byte payload; SEND will never suspend. "
                    "The OS is likely auto-tuning the receive buffer -- disable that "
                    "(e.g. 'sudo sysctl -w net.inet.tcp.doautorcvbuf=0' on macOS) and retry.")
            log(f"stalling {args.stall}s without reading -- this is what forces NERR_AGAIN")
            time.sleep(args.stall)
            conn.settimeout(2.0)
            total = 0
            try:
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    total += len(chunk)
            except socket.timeout:
                pass
            log(f"drained {total} bytes total, closing")
            conn.close()
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        server.close()
    return 0


def cmd_udp_echo(args: argparse.Namespace) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind, args.port))
    log(f"READY udp-echo bind={args.bind}:{args.port}")
    try:
        while True:
            data, addr = sock.recvfrom(65536)
            log(f"DATAGRAM from {addr[0]}:{addr[1]} ({len(data)} bytes)")
            sock.sendto(data, addr)
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        sock.close()
    return 0


def _dual_data_peer(server: socket.socket, once: bool) -> None:
    try:
        while True:
            conn, addr = server.accept()
            log(f"DATA conn from {addr[0]}:{addr[1]}, streaming counter")
            counter = 0
            try:
                while True:
                    conn.sendall(bytes((counter,)))
                    counter = (counter + 1) & 0xFF
            except OSError:
                pass
            conn.close()
            log("DATA conn closed")
            if once:
                break
    except OSError:
        pass


def cmd_dual(args: argparse.Namespace) -> int:
    # UNETTEST -2 DATAPORT HOST CTRLPORT: channel 0 connects to CTRLPORT and
    # sends one probe line; channel 1 connects to DATAPORT and expects a
    # continuous wrapping 0..255 byte counter (unettest.asm's DUAL_CHECK_SEQ).
    control = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    control.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    control.bind((args.bind, args.control_port))
    control.listen(1)
    data = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    data.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    data.bind((args.bind, args.data_port))
    data.listen(1)
    log(f"READY dual control={args.bind}:{args.control_port} data={args.bind}:{args.data_port}")
    data_thread = threading.Thread(target=_dual_data_peer, args=(data, args.once), daemon=True)
    data_thread.start()
    try:
        while True:
            conn, addr = control.accept()
            log(f"CONTROL conn from {addr[0]}:{addr[1]}")
            conn.settimeout(args.timeout)
            try:
                probe = conn.recv(4096)
                if probe:
                    log(f"CONTROL received {probe!r}")
                    conn.sendall(b"ack: " + probe)
            except socket.timeout:
                pass
            conn.close()
            if args.once:
                break
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        control.close()
        # In --once mode, control's own exchange is a single fast round trip
        # that finishes long before the data channel's drain loop does (a
        # real UNETTEST -2 run keeps reading channel 1 for a while after
        # sending its one control probe) -- so wait for the data side's own
        # natural one-connection cycle instead of cutting it off here.
        if args.once:
            data_thread.join(timeout=args.timeout)
        data.close()
        data_thread.join(timeout=2.0)
    return 0


def cmd_listen_client(args: argparse.Namespace) -> int:
    message = args.message.encode("ascii")
    for attempt in range(1, args.times + 1):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(args.timeout)
        log(f"attempt {attempt}/{args.times}: connecting to {args.host}:{args.port}")
        try:
            sock.connect((args.host, args.port))
        except OSError as exc:
            log(f"connect failed: {exc}")
            sock.close()
            return 1
        log("connected")
        sock.sendall(message)
        log(f"sent {len(message)} bytes")
        try:
            reply = sock.recv(4096)
        except socket.timeout:
            log("no reply within timeout")
            reply = b""
        if reply:
            log(f"reply ({len(reply)} bytes): {reply!r}")
        sock.close()
        if attempt < args.times:
            log(f"waiting {args.pause}s before the next attempt "
                f"(re-arm window is {LISTEN_ACCEPT_TIMEOUT_S:.0f}s)")
            time.sleep(args.pause)
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)

    p = sub.add_parser("tcp-echo")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_tcp_echo)

    p = sub.add_parser("tcp-refuse")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.set_defaults(func=cmd_tcp_refuse)

    p = sub.add_parser("tcp-stall")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--rcvbuf", type=int, default=700,
                   help="requested SO_RCVBUF (default: 700; must be > TCP_MSS=536 and "
                        f"< ASYNC_PAYLOAD_LEN={ASYNC_PAYLOAD_LEN})")
    p.add_argument("--stall", type=float, default=1.0,
                   help=f"seconds to accept-and-not-read (default: 1.0; must stay under "
                        f"{ASYNC_RESUME_BUDGET_MS / 1000:.1f}s)")
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_tcp_stall)

    p = sub.add_parser("udp-echo")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_udp_echo)

    p = sub.add_parser("dual")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--control-port", type=int, required=True)
    p.add_argument("--data-port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=cmd_dual)

    p = sub.add_parser("listen-client")
    p.add_argument("--host", required=True, help="Sprinter's IP")
    p.add_argument("--port", type=int, required=True, help="LISTENPORT passed to UNETTEST -l")
    p.add_argument("--times", type=int, default=2,
                   help="connections to make in a row (default: 2, to exercise the re-arm)")
    p.add_argument("--pause", type=float, default=2.0)
    p.add_argument("--message", default="hello from stage14_responder\n")
    p.add_argument("--timeout", type=float, default=10.0)
    p.set_defaults(func=cmd_listen_client)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except OSError as exc:
        sys.stderr.write(f"error: {exc}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
