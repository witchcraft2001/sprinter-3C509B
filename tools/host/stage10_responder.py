#!/usr/bin/env python3
"""Stage 10 raw DHCP/DNS/NTP/UDP/TFTP responder and public UDP proxy."""

import argparse
import ipaddress
import socket
import struct
import sys

import stage7_responder as stage7
import stage8_responder as stage8
import stage9_responder as stage9


CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
DHCP_IP = ipaddress.IPv4Address("192.168.7.1").packed
SERVICE_IP = ipaddress.IPv4Address("192.168.7.44").packed
CLIENT_MAC = bytes.fromhex("02608c123456")
SERVER_MAC = bytes.fromhex("020000000044")
LEASE_SECONDS = 86400
FIXED_UNIX_SECONDS = 1735732799  # 2025-01-01 11:59:59 UTC
DNS_NAMES = {
    "echo.stage10.test": SERVICE_IP,
    "ntp.stage10.test": SERVICE_IP,
    "tftp.stage10.test": SERVICE_IP,
}


def dhcp_details(frame):
    parsed = stage7.parse_dhcp(frame)
    if not parsed:
        return None
    bootp = frame[42:]
    parsed["ciaddr"] = bootp[12:16]
    parsed["source_ip"] = frame[26:30]
    return parsed


def dhcp_reply(request, reply_type, renewal=False):
    frame = bytearray(stage7.build_dhcp_reply(
        request, reply_type, SERVER_MAC, DHCP_IP, CLIENT_IP,
        ipaddress.IPv4Address("255.255.255.0").packed, DHCP_IP,
        SERVICE_IP + ipaddress.IPv4Address("1.1.1.1").packed,
        LEASE_SECONDS))
    if renewal and reply_type == 5:
        frame[58:62] = b"\0" * 4  # RFC renewal may ACK with yiaddr zero.
        frame[0:6] = request["mac"]
        frame[30:34] = request["ciaddr"]
        frame[24:26] = b"\0\0"
        struct.pack_into("!H", frame, 24, stage7.checksum(bytes(frame[14:34])))
        frame[40:42] = b"\0\0"
        udp = bytes(frame[34:])
        value = stage7.udp_ipv4(frame[26:30], frame[30:34], udp) or 0xFFFF
        struct.pack_into("!H", frame, 40, value)
    return bytes(frame)


def parse_dns_query(payload):
    if len(payload) < 17 or payload[2:4] != b"\x01\x00" or payload[4:6] != b"\0\x01":
        return None
    labels = []
    offset = 12
    wire = 1
    while offset < len(payload):
        length = payload[offset]
        offset += 1
        if not length:
            break
        if length > 63 or offset + length > len(payload) or wire + length + 1 > 255:
            return None
        label = payload[offset:offset + length]
        if any(value < 0x21 or value >= 0x7F for value in label):
            return None
        try:
            labels.append(label.decode("ascii"))
        except UnicodeDecodeError:
            return None
        offset += length
        wire += length + 1
    if not labels or offset + 4 != len(payload) or payload[offset:offset + 4] != b"\0\x01\0\x01":
        return None
    return {"id": payload[:2], "name": ".".join(labels).lower(),
            "question": payload[12:]}


def dns_reply(query, address=None, rcode=0, stale=False, malformed=False):
    xid = bytearray(query["id"])
    if stale:
        xid[1] ^= 1
    answers = 0 if rcode or address is None else 1
    payload = bytearray(xid + b"\x81" + bytes((0x80 | rcode,)) +
                        b"\0\x01\0" + bytes((answers,)) + b"\0\0\0\0" +
                        query["question"])
    if answers:
        if malformed:
            pointer = len(payload)
            payload += bytes((0xC0 | (pointer >> 8), pointer & 0xFF))
        else:
            payload += b"\xC0\x0C"
        payload += b"\0\x01\0\x01\0\0\0\x3C\0\x04" + address
    return bytes(payload)


def ntp_reply(request, unix_seconds=FIXED_UNIX_SECONDS, stale=False):
    if len(request) != 48:
        return None
    payload = bytearray(48)
    payload[0:4] = b"\x24\x02\x06\xEC"
    payload[24:32] = request[40:48]
    if stale:
        payload[31] ^= 1
    struct.pack_into("!I", payload, 40, (unix_seconds + 2208988800) & 0xFFFFFFFF)
    payload[44] = 0x80
    return bytes(payload)


class Responder:
    def __init__(self, profile="clean", upload_dir=None, proxy_enabled=True,
                 proxy_exchange=None):
        self.profile = profile
        self.proxy_enabled = proxy_enabled
        self.proxy_exchange = proxy_exchange or self._socket_exchange
        self.stage9 = stage9.Responder(profile, upload_dir)
        self.events = []
        self.counts = {"discover": 0, "request": 0, "renew": 0,
                       "release": 0, "dns": 0, "ntp": 0}

    @property
    def faults(self):
        return self.profile == "faults"

    def event(self, value):
        self.events.append(value)

    @staticmethod
    def _socket_exchange(destination, port, payload):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as channel:
            channel.settimeout(5.0)
            channel.sendto(payload, (str(ipaddress.IPv4Address(destination)), port))
            return channel.recvfrom(2048)[0]

    def proxy(self, request, port, destination=None):
        if not self.proxy_enabled:
            return []
        destination = destination or request["destination"]
        try:
            payload = self.proxy_exchange(destination, port, request["payload"])
        except (OSError, TimeoutError) as exc:
            self.event(f"PROXY error port={port} detail={exc}")
            return []
        self.event(f"PROXY ok destination={ipaddress.IPv4Address(destination)} "
                   f"port={port} bytes={len(payload)}")
        return [("PROXY", stage9.udp_reply(request, port, payload, SERVER_MAC))]

    def handle(self, frame):
        arp = stage7.parse_arp_request(frame)
        if arp and arp["target"] in (DHCP_IP, SERVICE_IP):
            self.event(f"FRAME ARP target={ipaddress.IPv4Address(arp['target'])}")
            return [("ARP", stage7.build_arp_reply(arp, SERVER_MAC))]
        dhcp = dhcp_details(frame)
        if dhcp:
            kind = dhcp["type"]
            if kind == 7:
                self.counts["release"] += 1
                self.event(f"RELEASE ciaddr={ipaddress.IPv4Address(dhcp['ciaddr'])}")
                return []
            if kind == 1:
                self.counts["discover"] += 1
                self.event(f"DHCP DISCOVER count={self.counts['discover']}")
                if self.faults and self.counts["discover"] == 1:
                    self.event("DROP DHCP DISCOVER")
                    return []
                return [("DHCP", dhcp_reply(dhcp, 2))]
            if kind == 3:
                renewal = dhcp["ciaddr"] != b"\0" * 4
                key = "renew" if renewal else "request"
                self.counts[key] += 1
                if self.counts[key] > 1:
                    self.event(f"RETRY DHCP {key} count={self.counts[key]}")
                self.event(f"DHCP {'RENEW' if renewal else 'REQUEST'}")
                if self.faults and renewal and self.counts[key] == 1:
                    self.event("DROP DHCP RENEW")
                    return []
                return [("DHCP", dhcp_reply(dhcp, 5, renewal))]
            return []
        echo = stage8.parse_echo_request(frame)
        if echo and echo["source"] == CLIENT_IP and echo["destination"] == SERVICE_IP:
            self.event("ICMP echo")
            return [("ICMP", stage8.echo_reply(echo, SERVER_MAC))]
        request = stage9.parse_udp(frame)
        if not request or request["source"] != CLIENT_IP:
            return []
        if request["destination_port"] == 53:
            self.counts["dns"] += 1
            if request["destination"] != SERVICE_IP:
                return self.proxy(request, 53)
            query = parse_dns_query(request["payload"])
            if not query:
                self.event("DNS malformed-query")
                return []
            name = query["name"]
            self.event(f"DNS name={name}")
            if name == "missing.stage10.test":
                body = dns_reply(query, rcode=3)
            elif name == "malformed.stage10.test":
                body = dns_reply(query, SERVICE_IP, malformed=True)
            elif name in DNS_NAMES:
                body = dns_reply(query, DNS_NAMES[name])
            else:
                return self.proxy(request, 53, ipaddress.IPv4Address("1.1.1.1").packed)
            replies = []
            if self.faults and self.counts["dns"] == 1:
                replies.append(("DNS", stage9.udp_reply(
                    request, 53, dns_reply(query, SERVICE_IP, stale=True), SERVER_MAC)))
                self.event("DROP stale DNS transaction")
            replies.append(("DNS", stage9.udp_reply(request, 53, body, SERVER_MAC)))
            return replies
        if request["destination_port"] == 123:
            self.counts["ntp"] += 1
            if request["destination"] != SERVICE_IP:
                return self.proxy(request, 123)
            body = ntp_reply(request["payload"])
            if body is None:
                return []
            self.event(f"NTP fixed={FIXED_UNIX_SECONDS}")
            replies = []
            if self.faults and self.counts["ntp"] == 1:
                replies.append(("NTP", stage9.udp_reply(
                    request, 123, ntp_reply(request["payload"], stale=True), SERVER_MAC)))
                self.event("DROP stale NTP cookie")
            replies.append(("NTP", stage9.udp_reply(request, 123, body, SERVER_MAC)))
            return replies
        replies = self.stage9.handle(frame)
        self.events.extend(self.stage9.events)
        self.stage9.events.clear()
        return replies


def serve(args, port):
    capture = stage7.PcapWriter(args.pcap)
    responder = Responder(args.profile, args.upload_dir, not args.no_proxy)
    sent = 0
    try:
        print(f"READY interface={args.interface} profile={args.profile} DHCP DNS NTP "
              f"echo={stage9.ECHO_PORT} tftp=69,6969 PROXY={'off' if args.no_proxy else 'on'}",
              flush=True)
        while not args.count or sent < args.count:
            frame = port.receive()
            if (stage7.parse_arp_request(frame) or stage7.parse_dhcp(frame) or
                    stage8.parse_echo_request(frame) or stage9.parse_udp(frame)):
                capture.write(frame)
            replies = responder.handle(frame)
            while responder.events:
                print(responder.events.pop(0), flush=True)
            for label, reply in replies:
                port.send(reply)
                capture.write(reply)
                sent += 1
                print(f"FRAME {sent} {label} bytes={len(reply)}", flush=True)
    finally:
        capture.close()
        port.close()
    return sent


def check_pcap(path):
    with open(path, "rb") as source:
        data = source.read()
    if len(data) < 24 or struct.unpack_from("<I", data)[0] != 0xA1B2C3D4:
        raise ValueError("not a little-endian classic pcap")
    offset = 24
    counts = {"frames": 0, "dhcp": 0, "release": 0, "dns": 0, "ntp": 0,
              "icmp": 0, "echo": 0, "tftp": 0}
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap record header")
        _sec, _usec, captured, wire = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if captured != wire or not 42 <= captured <= 1514 or offset + captured > len(data):
            raise ValueError("invalid classic-pcap record/FCS length")
        frame = data[offset:offset + captured]
        offset += captured
        if struct.unpack_from("!H", frame, 12)[0] == stage7.ETH_ARP:
            pass
        else:
            dhcp = dhcp_details(frame)
            udp = stage9.parse_udp(frame)
            if dhcp:
                counts["dhcp"] += 1
                counts["release"] += dhcp["type"] == 7
            elif udp:
                port_pair = (udp["source_port"], udp["destination_port"])
                if 53 in port_pair:
                    counts["dns"] += 1
                elif 123 in port_pair:
                    counts["ntp"] += 1
                elif stage9.ECHO_PORT in port_pair:
                    counts["echo"] += 1
                elif any(port in stage9.TFTP_PORTS + (stage9.SERVER_TID,) for port in port_pair):
                    counts["tftp"] += 1
            elif stage8.parse_echo_request(frame):
                counts["icmp"] += 1
            else:
                raise ValueError("malformed captured IPv4/UDP frame")
        counts["frames"] += 1
    required = ("dhcp", "release", "dns", "ntp", "echo", "tftp")
    if any(not counts[name] for name in required):
        raise ValueError("pcap lacks DHCP/RELEASE/DNS/NTP/echo/TFTP evidence")
    print("PCAP OK " + " ".join(f"{name}={value}" for name, value in counts.items()) +
          " checksums=valid no-fcs-record-lengths=exact")
    return counts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface")
    parser.add_argument("--pcap")
    parser.add_argument("--profile", choices=("clean", "faults"), default="clean")
    parser.add_argument("--upload-dir")
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--no-proxy", action="store_true")
    parser.add_argument("--check-pcap", metavar="FILE")
    parser.add_argument("--prepare-fixtures", metavar="DIR")
    args = parser.parse_args(argv)
    if args.prepare_fixtures:
        stage9.write_fixtures(args.prepare_fixtures)
        return 0
    if args.check_pcap:
        try:
            check_pcap(args.check_pcap)
            return 0
        except (OSError, ValueError) as exc:
            parser.exit(1, f"error: {exc}\n")
    if not args.interface:
        parser.error("--interface is required")
    if args.count < 0:
        parser.error("--count must be non-negative")
    try:
        serve(args, stage7.open_port(args.interface))
        return 0
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
