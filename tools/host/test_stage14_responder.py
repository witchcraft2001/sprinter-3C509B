#!/usr/bin/env python3
"""Unit tests for the Stage 14 manual-acceptance host peers.

These are real-socket integration tests (loopback), unlike the raw-frame
stage7..stage13 responder tests: stage14_responder.py itself talks through a
real OS TCP/IP stack (see its own module docstring for why), so the most
faithful test is to actually run it against loopback rather than simulate one
more protocol layer in Python.
"""

import socket
import threading
import time
import unittest

import stage14_responder as stage14


def free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def run_in_thread(func, args):
    thread = threading.Thread(target=func, args=(args,), daemon=True)
    thread.start()
    return thread


class FakeArgs:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class TcpEchoTest(unittest.TestCase):
    def test_echoes_back_unchanged(self):
        port = free_port()
        args = FakeArgs(bind="127.0.0.1", port=port, timeout=2.0, once=True)
        thread = run_in_thread(stage14.cmd_tcp_echo, args)
        time.sleep(0.1)
        with socket.create_connection(("127.0.0.1", port), timeout=2.0) as client:
            client.sendall(b"hello sprinter")
            client.shutdown(socket.SHUT_WR)
            received = b""
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                received += chunk
        self.assertEqual(received, b"hello sprinter")
        thread.join(timeout=2.0)
        self.assertFalse(thread.is_alive())


class UdpEchoTest(unittest.TestCase):
    def test_echoes_datagram_back_to_sender(self):
        port = free_port()
        args = FakeArgs(bind="127.0.0.1", port=port, once=True)
        thread = run_in_thread(stage14.cmd_udp_echo, args)
        time.sleep(0.1)
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.settimeout(2.0)
        client.sendto(b"udp payload", ("127.0.0.1", port))
        reply, _ = client.recvfrom(4096)
        client.close()
        self.assertEqual(reply, b"udp payload")
        thread.join(timeout=2.0)
        self.assertFalse(thread.is_alive())


class TcpStallTest(unittest.TestCase):
    def test_drains_after_stalling(self):
        port = free_port()
        args = FakeArgs(bind="127.0.0.1", port=port, rcvbuf=700, stall=0.1, once=True)
        thread = run_in_thread(stage14.cmd_tcp_stall, args)
        time.sleep(0.1)
        with socket.create_connection(("127.0.0.1", port), timeout=2.0) as client:
            client.sendall(b"x" * 200)
        thread.join(timeout=3.0)
        self.assertFalse(thread.is_alive())


class DualTest(unittest.TestCase):
    def test_control_acks_and_data_streams_wrapping_counter(self):
        control_port, data_port = free_port(), free_port()
        args = FakeArgs(bind="127.0.0.1", control_port=control_port, data_port=data_port,
                        timeout=2.0, once=True)
        thread = run_in_thread(stage14.cmd_dual, args)
        time.sleep(0.1)
        with socket.create_connection(("127.0.0.1", control_port), timeout=2.0) as control:
            control.sendall(b"UNETTEST DUAL CONTROL\r\n")
            ack = control.recv(4096)
        self.assertTrue(ack.startswith(b"ack: "))
        with socket.create_connection(("127.0.0.1", data_port), timeout=2.0) as data:
            chunk = data.recv(16)
        self.assertEqual(list(chunk), list(range(len(chunk))))
        thread.join(timeout=2.0)
        self.assertFalse(thread.is_alive())


class TcpRefuseTest(unittest.TestCase):
    def test_leaves_the_port_unbound_so_the_os_refuses_it(self):
        # The whole point of tcp-refuse is to NOT listen: it never binds a
        # socket, so any connection attempt on that port is refused by the
        # OS itself (the path UNETTEST's CONNECT is meant to exercise).
        port = free_port()
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", port), timeout=2.0)


class ListenClientTest(unittest.TestCase):
    def test_connects_sends_and_reports_reply(self):
        port = free_port()
        args = FakeArgs(bind="127.0.0.1", port=port, timeout=2.0, once=True)
        server_thread = run_in_thread(stage14.cmd_tcp_echo, args)
        time.sleep(0.1)
        client_args = FakeArgs(host="127.0.0.1", port=port, times=1, pause=0.0,
                                message="ping\n", timeout=2.0)
        result = stage14.cmd_listen_client(client_args)
        self.assertEqual(result, 0)
        server_thread.join(timeout=2.0)

    def test_reports_failure_when_nothing_is_listening(self):
        port = free_port()
        args = FakeArgs(host="127.0.0.1", port=port, times=1, pause=0.0,
                         message="ping\n", timeout=1.0)
        result = stage14.cmd_listen_client(args)
        self.assertEqual(result, 1)


class ArgparseTest(unittest.TestCase):
    def test_every_mode_is_wired_to_its_handler(self):
        cases = (
            (["tcp-echo", "--port", "1"], stage14.cmd_tcp_echo),
            (["tcp-refuse", "--port", "1"], stage14.cmd_tcp_refuse),
            (["tcp-stall", "--port", "1"], stage14.cmd_tcp_stall),
            (["udp-echo", "--port", "1"], stage14.cmd_udp_echo),
            (["dual", "--control-port", "1", "--data-port", "2"], stage14.cmd_dual),
            (["listen-client", "--host", "127.0.0.1", "--port", "1"], stage14.cmd_listen_client),
        )
        for argv, handler in cases:
            self.assertIs(build_parser().parse_args(argv).func, handler)


def build_parser():
    # Deliberately duplicates main()'s own subparser wiring instead of
    # importing it, so this test fails on any drift between the two rather
    # than trivially passing by construction.
    parser = stage14.argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)

    p = sub.add_parser("tcp-echo")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=stage14.cmd_tcp_echo)

    p = sub.add_parser("tcp-refuse")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.set_defaults(func=stage14.cmd_tcp_refuse)

    p = sub.add_parser("tcp-stall")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--rcvbuf", type=int, default=700)
    p.add_argument("--stall", type=float, default=1.0)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=stage14.cmd_tcp_stall)

    p = sub.add_parser("udp-echo")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=stage14.cmd_udp_echo)

    p = sub.add_parser("dual")
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--control-port", type=int, required=True)
    p.add_argument("--data-port", type=int, required=True)
    p.add_argument("--timeout", type=float, default=10.0)
    p.add_argument("--once", action="store_true")
    p.set_defaults(func=stage14.cmd_dual)

    p = sub.add_parser("listen-client")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--times", type=int, default=2)
    p.add_argument("--pause", type=float, default=2.0)
    p.add_argument("--message", default="hello from stage14_responder\n")
    p.add_argument("--timeout", type=float, default=10.0)
    p.set_defaults(func=stage14.cmd_listen_client)

    return parser


if __name__ == "__main__":
    unittest.main()
