#!/usr/bin/env python3
"""Deterministic raw-Ethernet PASV FTP responder and pcap checker for Stage 13.

Mirrors stage12_responder.py's shape: a small reactive server built on top of
stage11's TCP framing, reused here for TWO kinds of connection instead of one.
The control channel (a fixed port, 21) pushes an unsolicited "220" banner the
moment it comes up and answers a small FTP verb table; PASV self-announces a
data port the same way the Stage 9 TFTP responder announces its own TID, and
that data channel either pushes a fixture (RETR/LIST) or captures an upload
(STOR), filling the client's advertised window instead of replying one
segment per received frame -- see test_response_fills_the_advertised_window
in the unit tests below for why that distinction matters.

Connections are keyed by (source_port, destination_port) so the control
channel and the self-announced data channel never collide even though they
share the same client and server IPs.
"""

import argparse
import hashlib
import ipaddress
import os
import struct
import sys

import stage7_responder as stage7
import stage9_responder as stage9
import stage10_responder as stage10
import stage11_responder as stage11


CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
SERVICE_IP = ipaddress.IPv4Address("192.168.7.44").packed
SERVER_MAC = bytes.fromhex("020000000044")
CONTROL_PORT = 21
FIRST_DATA_PORT = 44000
BANNER = b"220 Stage13 test FTP ready.\r\n"
# Plain HTTP on the same session/image so DLSPEED's joint speed comparison
# (see specs.md) doesn't need a second responder process: any GET gets
# HTTP_LARGE back as a 200 with Content-Length, which is all DLSPEED asks of
# a server (no Range, no redirects, no chunking -- see docs/DLSPEED.md). This
# response deliberately stays open after its declared body so both clients
# prove that Content-Length, not FIN, stops the timed interval. It is its own,
# much bigger fixture, not FTP's 3000-byte LARGE:
# DSS's RTC has one-second resolution, so a transfer that completes inside
# one tick (as FTP's LARGE.BIN does over a 100 Mbit/s virtual link) is
# rejected by DLSPEED itself as "sample too short" and, even when it isn't,
# a one-second sample is too quantized to trust -- docs/DLSPEED.md asks for
# "4 MiB". Bumping FTP's own LARGE instead would also perturb the
# 5-MSS-window assertions the FTP data-channel tests are built around.
HTTP_PORT = 80
HTTP_LARGE = bytes((index * 37 + 11) & 0xFF for index in range(4 * 1024 * 1024))
# docs/STAGE13_TESTING_RU.md tells the operator to run FTP/NSLOOKUP against
# this name; DNS resolution has to actually work for that procedure to mean
# anything.
DNS_NAME = "ftp.stage13.test"

# Same shape as stage12_responder's SMALL/LARGE, sized to stay clear of a
# known receive-window limitation (see the Stage 13 test-infra report -- a
# GET past roughly 3.2KB on the FTP data channel currently fails; LARGE here
# is chosen to stay well under that so the MAME acceptance flow this
# responder ultimately serves gets a clean transfer).
SMALL = bytes((index * 13 + 5) & 0xFF for index in range(211))
LARGE = bytes((index * 37 + 11) & 0xFF for index in range(3000))
LISTING = b"-rw-r--r-- 1 owner group 211 Jan  1 00:00 SMALL.BIN\r\n"


def fixtures():
    return {"SMALL.BIN": SMALL, "LARGE.BIN": LARGE}


class Connection:
    def __init__(self, isn, client_next, window):
        self.server_isn = isn
        self.server_next = (isn + 1) & 0xFFFFFFFF
        self.server_acked = (isn + 1) & 0xFFFFFFFF
        self.client_next = client_next
        self.client_window = window
        self.established = False
        self.send_queue = bytearray()
        self.fin_sent = False
        self.accum = bytearray()
        self.uploaded = bytearray()
        self.last_request = None
        self.http_answered = False


class Responder:
    def __init__(self, profile="clean"):
        self.profile = profile
        self.connections = {}
        self.events = []
        self.requests = []
        self.uploads = {}
        self.data_port = None
        self.pending_verb = None
        self.pending_verb_pushed = False
        # REST offset requested for the *next* RETR only -- a real server
        # forgets it once the transfer command is accepted, so a later RETR
        # with no REST starts at 0 again.
        self.rest_offset = 0
        self.control_key = None
        self.next_data_port = FIRST_DATA_PORT
        # Extra frames generated out-of-band (pushing a data-channel fixture
        # the instant a RETR/LIST command is accepted, or a "226" onto the
        # control channel once a transfer's FIN goes out) -- collected here
        # and flushed into handle()'s own return value.
        self._extra = []

    def event(self, value):
        self.events.append(value)

    # -- shared TCP plumbing (mirrors stage12_responder.Responder.handle) --

    def handle(self, frame):
        arp = stage7.parse_arp_request(frame)
        if arp and arp["target"] == SERVICE_IP:
            self.event("ARP service")
            return [("ARP", stage7.build_arp_reply(arp, SERVER_MAC))]
        udp = stage9.parse_udp(frame)
        if (udp and udp["source"] == CLIENT_IP and udp["destination"] == SERVICE_IP
                and udp["destination_port"] == 53):
            query = stage10.parse_dns_query(udp["payload"])
            if not query or query["name"] != DNS_NAME:
                return []
            self.event(f"DNS name={query['name']}")
            body = stage10.dns_reply(query, SERVICE_IP)
            return [("DNS", stage9.udp_reply(udp, 53, body, SERVER_MAC))]
        request = stage11.parse_tcp(frame)
        if (not request or request["source"] != CLIENT_IP or
                request["destination"] != SERVICE_IP):
            return []
        port = request["destination_port"]
        if port != CONTROL_PORT and port != self.data_port and port != HTTP_PORT:
            return []
        key = (request["source_port"], port)
        kind = "control" if port == CONTROL_PORT else ("http" if port == HTTP_PORT else "data")
        replies = []

        if request["flags"] & 4:  # RST
            self.connections.pop(key, None)
            return []

        if request["flags"] & 2:  # SYN
            ordinal = len(self.connections) + 1
            isn = (0x13B00000 + ordinal * 0x10000) & 0xFFFFFFFF
            connection = Connection(isn, (request["sequence"] + 1) & 0xFFFFFFFF,
                                     request["window"])
            connection.last_request = request
            self.connections[key] = connection
            if kind == "control":
                self.control_key = key
            self.event(f"SYN {kind} port={key}")
            replies.append(("SYNACK", stage11.build_tcp(
                request, connection.server_isn, connection.client_next, 0x12)))
            return replies

        connection = self.connections.get(key)
        if connection is None:
            return [("RST", stage11.build_tcp(request, 0, 0, 4, window=0))]
        connection.last_request = request
        connection.client_window = request["window"]
        if request["flags"] & 0x10:
            acked = (request["acknowledgement"] - connection.server_acked) & 0xFFFFFFFF
            outstanding = (connection.server_next - connection.server_acked) & 0xFFFFFFFF
            if acked <= outstanding:
                connection.server_acked = request["acknowledgement"]

        if (not connection.established and not request["payload"] and
                not (request["flags"] & 1) and
                request["acknowledgement"] == connection.server_next):
            connection.established = True
            if kind == "control":
                connection.send_queue.extend(BANNER)
            self.event(f"ESTABLISHED {kind} port={key}")
            # Falls through to the generic drain below so the banner goes
            # out immediately instead of waiting for a frame that never
            # comes on an otherwise-idle connection.

        if request["payload"] and request["sequence"] == connection.client_next:
            connection.client_next = (connection.client_next +
                                       len(request["payload"])) & 0xFFFFFFFF
            if kind == "control":
                self._handle_control_data(connection, bytes(request["payload"]))
            elif kind == "http":
                self._handle_http_data(connection, bytes(request["payload"]))
            else:
                connection.uploaded.extend(request["payload"])

        if request["flags"] & 1:  # FIN
            connection.client_next = (connection.client_next + 1) & 0xFFFFFFFF
            reply = stage11.build_tcp(request, connection.server_next,
                                       connection.client_next,
                                       0x10 if connection.fin_sent else 0x11)
            replies.append(("FIN-ACK" if not connection.fin_sent else "ACK", reply))
            if not connection.fin_sent:
                connection.fin_sent = True
                connection.server_next = (connection.server_next + 1) & 0xFFFFFFFF
                if (kind == "data" and self.pending_verb and
                        self.pending_verb[0] == "STOR"):
                    self.uploads[self.pending_verb[1]] = bytes(connection.uploaded)
                    if self.profile != "suppress226":
                        self._send_226()
            replies.extend(self._flush_extra())
            return replies

        replies.extend(self._drain(connection, request, kind))
        replies.extend(self._flush_extra())
        return replies

    def _drain(self, connection, request, kind):
        replies = []
        sent_any = False
        while connection.send_queue:
            in_flight = (connection.server_next - connection.server_acked) & 0xFFFFFFFF
            available = max(0, connection.client_window - in_flight)
            if not available:
                break
            size = min(stage11.TCP_MSS, available, len(connection.send_queue))
            payload = bytes(connection.send_queue[:size])
            del connection.send_queue[:size]
            sent_any = True
            finish = (kind == "data" and not connection.send_queue and
                      not connection.fin_sent)
            flags = 0x19 if finish else 0x18
            reply = stage11.build_tcp(request, connection.server_next,
                                       connection.client_next, flags, payload)
            connection.server_next = (connection.server_next + size +
                                       (1 if finish else 0)) & 0xFFFFFFFF
            replies.append(({"data": "DATA", "http": "HTTP"}.get(kind, "REPLY"), reply))
            if finish:
                connection.fin_sent = True
                if kind == "data" and self.profile != "suppress226":
                    self._send_226()
        if not sent_any and request["payload"]:
            replies.append(("ACK", stage11.build_tcp(
                request, connection.server_next, connection.client_next, 0x10)))
        return replies

    def _send_226(self):
        connection = self.connections.get(self.control_key)
        if connection is None or connection.last_request is None:
            return
        connection.send_queue.extend(b"226 Transfer complete.\r\n")
        self._extra.extend(self._drain(connection, connection.last_request, "control"))

    def _flush_extra(self):
        extra, self._extra = self._extra, []
        return extra

    # -- FTP command dialog --

    def _handle_control_data(self, connection, payload):
        connection.accum.extend(payload)
        while b"\r\n" in connection.accum:
            index = connection.accum.index(b"\r\n")
            line = bytes(connection.accum[:index]).decode("latin1")
            del connection.accum[:index + 2]
            self.requests.append(line)
            # repr() so a stray CR, NUL, or non-ASCII byte the client sent is
            # visible in the log instead of being silently swallowed by the
            # terminal -- exactly the kind of corruption a 550/silent-RETR
            # mismatch against an argument that "looks right" on screen
            # would need this to actually catch.
            self.event(f"CMD {line!r}")
            reply = self._reply_for(line)
            if reply:
                connection.send_queue.extend(reply.encode("latin1"))
            # Deferred until "150" is actually queued above: pushing the
            # data-channel fixture from inside _reply_for can complete a
            # small transfer (and queue its "226") before the caller has
            # appended this very reply, sending 226 ahead of 150 on the
            # wire -- no real server does that, even though ftp.asm's
            # reader tolerates whatever order replies arrive in.
            if self.pending_verb and self.pending_verb[0] != "STOR" and not self.pending_verb_pushed:
                self.pending_verb_pushed = True
                self._push_fixture(*self.pending_verb)

    # -- plain HTTP (DLSPEED only) --

    def _handle_http_data(self, connection, payload):
        if connection.http_answered:
            return
        connection.accum.extend(payload)
        if b"\r\n\r\n" not in connection.accum:
            return
        connection.http_answered = True
        line = bytes(connection.accum).split(b"\r\n", 1)[0].decode("ascii", "replace")
        self.requests.append(line)
        self.event(f"HTTP {line!r}")
        body = HTTP_LARGE
        head = (f"HTTP/1.0 200 OK\r\nContent-Length: {len(body)}\r\n"
                "Connection: keep-alive\r\n\r\n").encode("ascii")
        connection.send_queue.extend(head + body)

    def _reply_for(self, line):
        parts = line.split(" ", 1)
        verb = parts[0].upper()
        arg = parts[1] if len(parts) > 1 else ""
        if verb == "USER":
            return "331 User %s OK, need password.\r\n" % arg
        if verb == "PASS":
            if self.profile == "refuse-pass":
                return "530 Login incorrect.\r\n"
            return "230 Login successful.\r\n"
        if verb == "TYPE":
            return "200 Type set to I.\r\n"
        if verb == "SIZE":
            body = fixtures().get(arg.upper())
            if body is None:
                return "550 Could not get file size.\r\n"
            return "213 %d\r\n" % len(body)
        if verb == "PASV":
            self.data_port = self.next_data_port
            self.next_data_port += 1
            ip = SERVICE_IP
            port = self.data_port
            return "227 Entering Passive Mode (%d,%d,%d,%d,%d,%d).\r\n" % (
                ip[0], ip[1], ip[2], ip[3], (port >> 8) & 0xFF, port & 0xFF)
        if verb == "REST":
            try:
                offset = int(arg)
            except ValueError:
                return "501 Invalid REST argument.\r\n"
            if offset < 0:
                return "501 Invalid REST argument.\r\n"
            self.rest_offset = offset
            return "350 Restarting at %s.\r\n" % arg
        if verb in ("RETR", "LIST", "STOR"):
            # A real server only honors REST on the RETR it immediately
            # precedes; a fresh transfer without its own REST starts at 0
            # even if an earlier one left an offset behind.
            offset = self.rest_offset if verb == "RETR" else 0
            self.rest_offset = 0
            self.pending_verb = (verb, arg, offset)
            self.pending_verb_pushed = False
            return "150 Opening data connection.\r\n"
        if verb == "QUIT":
            return "221 Goodbye.\r\n"
        return "500 Unknown command.\r\n"

    def _push_fixture(self, verb, arg, offset=0):
        for key, connection in self.connections.items():
            if key[1] != self.data_port or not connection.established:
                continue
            body = LISTING if verb == "LIST" else fixtures().get(arg.upper(), b"")
            connection.send_queue.extend(body[offset:])
            if connection.last_request is not None:
                self._extra.extend(self._drain(connection, connection.last_request, "data"))
            return


def serve(args, port):
    capture = stage7.PcapWriter(args.pcap)
    responder = Responder(args.profile)
    log = open(args.log, "w", encoding="utf-8")
    try:
        message = (f"READY interface={args.interface} profile={args.profile} "
                   f"control={CONTROL_PORT}")
        print(message, flush=True)
        print(message, file=log, flush=True)
        while True:
            frame = port.receive()
            if (stage7.parse_arp_request(frame) or stage9.parse_udp(frame) or
                    stage11.parse_tcp(frame)):
                capture.write(frame)
            for label, reply in responder.handle(frame):
                port.send(reply)
                capture.write(reply)
                print(f"FRAME {label} bytes={len(reply)}", file=log, flush=True)
            while responder.events:
                event = responder.events.pop(0)
                print(event, flush=True)
                print(event, file=log, flush=True)
    finally:
        log.close()
        capture.close()
        port.close()


def pcap_frames(path):
    data = open(path, "rb").read()
    if len(data) < 24 or struct.unpack_from("<I", data)[0] != 0xA1B2C3D4:
        raise ValueError("not a little-endian classic pcap")
    offset, frames = 24, []
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap")
        _sec, _usec, captured, wire = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if captured != wire or offset + captured > len(data):
            raise ValueError("invalid pcap record")
        frames.append(data[offset:offset + captured])
        offset += captured
    return frames


def check_pcap(path):
    frames = pcap_frames(path)
    tcp = [stage11.parse_tcp(frame) for frame in frames]
    tcp = [item for item in tcp if item]
    client_payload = b"".join(item["payload"] for item in tcp
                              if item["source"] == CLIENT_IP and item["payload"])
    if b"USER " not in client_payload or b"PASV" not in client_payload:
        raise ValueError("pcap lacks a USER command and a PASV request")
    if (b"RETR " not in client_payload and b"STOR " not in client_payload and
            b"LIST" not in client_payload):
        raise ValueError("pcap lacks an FTP transfer verb")
    if not any(item["flags"] & 2 and item["source"] == CLIENT_IP and
               item["destination_port"] == CONTROL_PORT for item in tcp):
        raise ValueError("pcap lacks a client SYN to the control port")
    print(f"PCAP OK frames={len(frames)} tcp={len(tcp)} "
          f"sha256={hashlib.sha256(open(path, 'rb').read()).hexdigest()}")


def prepare(directory):
    os.makedirs(directory, exist_ok=True)
    for name, body in fixtures().items():
        with open(os.path.join(directory, name), "wb") as output:
            output.write(body)
        print(f"{name} {len(body)} {hashlib.sha256(body).hexdigest()}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface")
    parser.add_argument("--pcap")
    parser.add_argument("--log")
    parser.add_argument("--profile", choices=("clean", "refuse-pass", "suppress226"),
                        default="clean")
    parser.add_argument("--check-pcap")
    parser.add_argument("--prepare-fixtures")
    args = parser.parse_args(argv)
    try:
        if args.prepare_fixtures:
            prepare(args.prepare_fixtures)
            return 0
        if args.check_pcap:
            check_pcap(args.check_pcap)
            return 0
        if not args.interface or not args.pcap or not args.log:
            parser.error("--interface, --pcap and --log are required")
        serve(args, stage7.open_port(args.interface))
        return 0
    except (OSError, ValueError) as exc:
        parser.exit(1, f"error: {exc}\n")
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
