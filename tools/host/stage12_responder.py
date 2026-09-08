#!/usr/bin/env python3
"""Deterministic raw DNS/HTTP responder and pcap checker for Stage 12."""

import argparse
import hashlib
import ipaddress
import os
import re
import struct
import sys

import stage7_responder as stage7
import stage9_responder as stage9
import stage10_responder as stage10
import stage11_responder as stage11


CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
SERVICE_IP = ipaddress.IPv4Address("192.168.7.44").packed
SERVER_MAC = bytes.fromhex("020000000044")
HTTP_PORT = 80
DNS_NAME = "wget.stage12.test"
SMALL = bytes((index * 13 + 5) & 0xFF for index in range(1537))
LARGE = bytes((index * 37 + 11) & 0xFF for index in range(70001))


def fixtures():
    return {"ZERO.BIN": b"", "SMALL.BIN": SMALL, "LARGE.BIN": LARGE,
            "RANGE.BIN": LARGE, "CLOSE.BIN": SMALL}


def http_response(status, body=b"", headers=None, content_length=True):
    fields = dict(headers or {})
    if content_length:
        fields["Content-Length"] = str(len(body))
    head = "HTTP/1.0 " + status + "\r\n"
    head += "".join(f"{name}: {value}\r\n" for name, value in fields.items())
    return head.encode("ascii") + b"\r\n" + body


def endpoint(target, request):
    path = target.split("?", 1)[0].upper()
    if path == "/REDIRECT":
        return http_response("302 Found", headers={"Location": "/SMALL.BIN"})
    if path == "/ABSOLUTE":
        return http_response("301 Moved Permanently", headers={
            "Location": "http://wget.stage12.test/SMALL.BIN"})
    if path == "/404":
        return http_response("404 Not Found", b"not written")
    if path == "/500":
        return http_response("500 Internal Server Error", b"not written")
    name = path.lstrip("/") or "ZERO.BIN"
    body = fixtures().get(name)
    if body is None:
        return http_response("404 Not Found", b"not written")
    match = re.search(br"(?im)^Range:[ \t]*bytes=([0-9]+)-[ \t]*\r?$", request)
    if match:
        offset = int(match.group(1))
        if offset >= len(body):
            return http_response("416 Range Not Satisfiable")
        return http_response("206 Partial Content", body[offset:], {
            "Content-Range": f"bytes {offset}-{len(body) - 1}/{len(body)}"})
    return http_response("200 OK", body, content_length=name != "CLOSE.BIN")


class Responder:
    def __init__(self, profile="clean"):
        self.profile = profile
        self.connections = {}
        self.events = []
        self.requests = []

    def event(self, value):
        self.events.append(value)

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
                request["destination"] != SERVICE_IP or
                request["destination_port"] != HTTP_PORT):
            return []
        key = request["source_port"]
        if request["flags"] & 4:
            self.connections.pop(key, None)
            return []
        if request["flags"] & 2:
            client_next = (request["sequence"] + 1) & 0xFFFFFFFF
            connection = self.connections.get(key)
            if connection is None or connection["client_next"] != client_next:
                isn = (0x509B1200 + len(self.connections) * 0x10000) & 0xFFFFFFFF
                connection = {"client_next": client_next, "server_next": isn + 1,
                              "server_acked": isn + 1, "isn": isn, "window": 536,
                              "request": bytearray(), "pending": bytearray(),
                              "ready": False, "fin": False}
                self.connections[key] = connection
            self.event(f"SYN port={key} mss={request['mss']}")
            return [("SYNACK", stage11.build_tcp(
                request, connection["isn"], connection["client_next"], 0x12))]
        connection = self.connections.get(key)
        if connection is None:
            return [("RST", stage11.build_tcp(request, 0, 0, 4, window=0))]
        connection["window"] = request["window"]
        if request["flags"] & 0x10:
            acknowledged = (request["acknowledgement"] - connection["server_acked"]) & 0xFFFFFFFF
            outstanding = (connection["server_next"] - connection["server_acked"]) & 0xFFFFFFFF
            if acknowledged <= outstanding:
                connection["server_acked"] = request["acknowledgement"]
        accepted = False
        if request["payload"] and request["sequence"] == connection["client_next"]:
            accepted = True
            connection["client_next"] = (connection["client_next"] + len(request["payload"])) & 0xFFFFFFFF
            connection["request"].extend(request["payload"])
            if not connection["ready"] and b"\r\n\r\n" in connection["request"]:
                raw = bytes(connection["request"])
                line = raw.split(b"\r\n", 1)[0].decode("ascii", "replace")
                parts = line.split(" ")
                target = parts[1] if len(parts) == 3 and parts[0] == "GET" else "/404"
                connection["pending"].extend(endpoint(target, raw))
                connection["ready"] = True
                self.requests.append(raw)
                self.event(f"HTTP target={target} range={'yes' if b'Range:' in raw else 'no'}")
        if request["flags"] & 1:
            connection["client_next"] = (connection["client_next"] + 1) & 0xFFFFFFFF
        # Fill the window the client advertised instead of answering one segment
        # per received frame. A strictly reactive responder is a stop-and-wait
        # pipe no matter how large a window the client offers, which made every
        # receive-window measurement taken against it meaningless.
        replies = []
        while connection["pending"]:
            in_flight = (connection["server_next"] - connection["server_acked"]) & 0xFFFFFFFF
            available = max(0, connection["window"] - in_flight)
            if not available:
                break
            size = min(stage11.TCP_MSS, available, len(connection["pending"]))
            payload = bytes(connection["pending"][:size])
            del connection["pending"][:size]
            finish = not connection["pending"] and self.profile != "stall"
            flags = 0x19 if finish else 0x18
            reply = stage11.build_tcp(request, connection["server_next"],
                                      connection["client_next"], flags, payload)
            connection["server_next"] = (connection["server_next"] + size + (1 if finish else 0)) & 0xFFFFFFFF
            connection["fin"] = finish
            replies.append(("HTTP", reply))
        if replies:
            return replies
        if accepted or request["payload"]:
            return [("ACK", stage11.build_tcp(request, connection["server_next"],
                                                connection["client_next"], 0x10))]
        return []


def serve(args, port):
    capture = stage7.PcapWriter(args.pcap)
    responder = Responder(args.profile)
    log = open(args.log, "w", encoding="utf-8")
    try:
        message = f"READY interface={args.interface} profile={args.profile} dns={DNS_NAME} http={HTTP_PORT}"
        print(message, flush=True); print(message, file=log, flush=True)
        while True:
            frame = port.receive()
            if stage7.parse_arp_request(frame) or stage9.parse_udp(frame) or stage11.parse_tcp(frame):
                capture.write(frame)
            for label, reply in responder.handle(frame):
                port.send(reply); capture.write(reply)
                print(f"FRAME {label} bytes={len(reply)}", file=log, flush=True)
            while responder.events:
                event = responder.events.pop(0)
                print(event, flush=True); print(event, file=log, flush=True)
    finally:
        log.close(); capture.close(); port.close()


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
        frames.append(data[offset:offset + captured]); offset += captured
    return frames


def check_pcap(path):
    frames = pcap_frames(path)
    tcp = [stage11.parse_tcp(frame) for frame in frames]
    tcp = [item for item in tcp if item]
    client_payload = b"".join(item["payload"] for item in tcp
                              if item["source"] == CLIENT_IP and item["payload"])
    if b"GET " not in client_payload or b"Host:" not in client_payload:
        raise ValueError("pcap lacks an HTTP/1.0 GET and Host header")
    if b"Range: bytes=65536-" not in client_payload:
        raise ValueError("pcap lacks the deterministic 65536-byte resume request")
    if not any(item["flags"] & 2 and item["source"] == CLIENT_IP and
               item["mss"] == stage11.TCP_MSS for item in tcp):
        raise ValueError("pcap lacks a client MSS-536 SYN")
    if not any(stage9.parse_udp(frame) and stage9.parse_udp(frame)["destination_port"] == 53
               for frame in frames):
        raise ValueError("pcap lacks DNS query evidence")
    print(f"PCAP OK frames={len(frames)} tcp={len(tcp)} http_bytes={len(client_payload)} "
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
    parser.add_argument("--profile", choices=("clean", "stall"), default="clean")
    parser.add_argument("--check-pcap")
    parser.add_argument("--prepare-fixtures")
    args = parser.parse_args(argv)
    try:
        if args.prepare_fixtures:
            prepare(args.prepare_fixtures); return 0
        if args.check_pcap:
            check_pcap(args.check_pcap); return 0
        if not args.interface or not args.pcap or not args.log:
            parser.error("--interface, --pcap and --log are required")
        serve(args, stage7.open_port(args.interface)); return 0
    except (OSError, ValueError) as exc:
        parser.exit(1, f"error: {exc}\n")
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
