#!/usr/bin/env python3
"""Reactive ARP/ICMP Stage 8 responder with classic-pcap capture."""

import argparse
import ipaddress
import struct
import sys
import time

from stage7_responder import PcapWriter, checksum, mac_bytes, open_port, parse_arp_request


ETH_IP = 0x0800
CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
LOCAL_IP = ipaddress.IPv4Address("192.168.7.44").packed
GATEWAY_IP = ipaddress.IPv4Address("192.168.7.1").packed
EXTERNAL_IP = ipaddress.IPv4Address("203.0.113.10").packed
LOCAL_MAC = mac_bytes("02:00:00:00:00:44")
GATEWAY_MAC = mac_bytes("02:00:00:00:00:01")


def parse_echo_request(frame):
    if len(frame) < 42 or struct.unpack_from("!H", frame, 12)[0] != ETH_IP:
        return None
    ip = frame[14:]
    if ip[0] != 0x45 or ip[9] != 1 or checksum(ip[:20]):
        return None
    total = struct.unpack_from("!H", ip, 2)[0]
    if total < 28 or total > 1500 or total > len(ip) or ip[6] & 0xBF or ip[7]:
        return None
    icmp = ip[20:total]
    if icmp[0:2] != b"\x08\x00" or checksum(icmp):
        return None
    return {
        "ether_source": frame[6:12], "source": ip[12:16], "destination": ip[16:20],
        "ip": ip[:total], "icmp": icmp,
    }


def ipv4_packet(source, destination, payload, ttl=63, identifier=0x4321):
    total = 20 + len(payload)
    header = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, identifier,
                                   0x4000, ttl, 1, 0, source, destination))
    struct.pack_into("!H", header, 10, checksum(bytes(header)))
    return bytes(header) + payload


def echo_reply(request, source_mac, *, unrelated=False, bad_ip=False,
               bad_icmp=False, corrupt_payload=False):
    body = bytearray(request["icmp"])
    body[0] = 0
    if unrelated:
        body[4] ^= 1
    if corrupt_payload and len(body) > 8:
        body[8] ^= 1
    body[2:4] = b"\0\0"
    struct.pack_into("!H", body, 2, checksum(bytes(body)))
    if bad_icmp:
        body[2] ^= 1
    packet = bytearray(ipv4_packet(request["destination"], request["source"], bytes(body)))
    if bad_ip:
        packet[10] ^= 1
    return (request["ether_source"] + source_mac + struct.pack("!H", ETH_IP) + packet).ljust(60, b"\0")


def unreachable(request, source_mac, router_ip=GATEWAY_IP, code=1):
    body = bytearray(b"\x03" + bytes((code,)) + b"\0" * 6 + request["ip"][:28])
    struct.pack_into("!H", body, 2, checksum(bytes(body)))
    packet = ipv4_packet(router_ip, request["source"], bytes(body), ttl=64, identifier=0x2222)
    return request["ether_source"] + source_mac + struct.pack("!H", ETH_IP) + packet


def arp_reply(request, source_mac):
    body = (b"\x00\x01\x08\x00\x06\x04\x00\x02" + source_mac +
            request["target"] + request["mac"] + request["ip"])
    return (request["mac"] + source_mac + struct.pack("!H", 0x0806) + body).ljust(60, b"\0")


def replies_for_echo(request, scenario):
    source_mac = LOCAL_MAC if request["destination"] == LOCAL_IP else GATEWAY_MAC
    if scenario == "drop":
        return []
    if scenario == "unreachable":
        return [unreachable(request, GATEWAY_MAC)]
    if scenario == "noise":
        return [
            echo_reply(request, source_mac, unrelated=True),
            echo_reply(request, source_mac, bad_ip=True),
            echo_reply(request, source_mac, bad_icmp=True),
            echo_reply(request, source_mac, corrupt_payload=True),
            echo_reply(request, source_mac),
        ]
    return [echo_reply(request, source_mac)]


def serve(args, port):
    capture = PcapWriter(args.pcap)
    sent = 0
    try:
        print(f"READY interface={args.interface} scenario={args.scenario} "
              f"local=192.168.7.44 gateway=192.168.7.1 external=203.0.113.10", flush=True)
        while not args.count or sent < args.count:
            frame = port.receive()
            arp = parse_arp_request(frame)
            echo = parse_echo_request(frame)
            if not arp and not echo:
                continue
            capture.write(frame)
            replies = []
            label = ""
            if arp:
                if arp["target"] == LOCAL_IP:
                    replies = [arp_reply(arp, LOCAL_MAC)]
                elif arp["target"] == GATEWAY_IP:
                    replies = [arp_reply(arp, GATEWAY_MAC)]
                label = "ARP"
            elif echo and echo["source"] == CLIENT_IP and echo["destination"] in (
                    LOCAL_IP, GATEWAY_IP, EXTERNAL_IP):
                replies = replies_for_echo(echo, args.scenario)
                label = "ICMP"
            if not replies and echo:
                print(f"DROP ICMP target={ipaddress.IPv4Address(echo['destination'])}", flush=True)
            for reply in replies:
                if args.scenario == "delay" and echo:
                    time.sleep(args.delay)
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
    frames = 0
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap record header")
        _sec, _usec, captured, wire = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if captured != wire or captured < 42 or captured > 1514 or offset + captured > len(data):
            raise ValueError("invalid captured/wire length or truncated frame")
        frame = data[offset:offset + captured]
        offset += captured
        if frame[12:14] not in (b"\x08\x00", b"\x08\x06"):
            raise ValueError("unexpected EtherType")
        if frame[12:14] == b"\x08\x06":
            if frame[14:20] != b"\x00\x01\x08\x00\x06\x04" or frame[20:22] not in (
                    b"\x00\x01", b"\x00\x02"):
                raise ValueError("malformed ARP framing")
            if len(frame) > 42 and any(frame[42:]):
                raise ValueError("nonzero ARP padding")
        else:
            ip = frame[14:]
            if ip[0] != 0x45 or ip[9] != 1 or ip[6] & 0xBF or ip[7] or checksum(ip[:20]):
                raise ValueError("malformed IPv4 header")
            total = struct.unpack_from("!H", ip, 2)[0]
            if total < 28 or total > 1500 or total > len(ip) or checksum(ip[20:total]):
                raise ValueError("malformed ICMP length/checksum")
            if any(ip[total:]):
                raise ValueError("nonzero Ethernet padding after IPv4 total length")
            source, destination, icmp_type = ip[12:16], ip[16:20], ip[20]
            if source == CLIENT_IP:
                if destination not in (LOCAL_IP, GATEWAY_IP, EXTERNAL_IP):
                    raise ValueError("unexpected request destination")
                expected_mac = LOCAL_MAC if destination == LOCAL_IP else GATEWAY_MAC
                if frame[:6] != expected_mac or icmp_type != 8:
                    raise ValueError("wrong request MAC/type")
            elif destination == CLIENT_IP:
                expected_mac = LOCAL_MAC if source == LOCAL_IP else GATEWAY_MAC
                if frame[6:12] != expected_mac or icmp_type not in (0, 3):
                    raise ValueError("wrong response MAC/type")
            else:
                raise ValueError("unexpected IPv4 endpoints")
            if icmp_type in (0, 8):
                payload = ip[28:total]
                if payload != bytes(index & 255 for index in range(len(payload))):
                    raise ValueError("Echo payload is not the byte-index pattern")
        frames += 1
    if not frames:
        raise ValueError("pcap has no frames")
    print(f"PCAP OK frames={frames} no-fcs-record-lengths=exact")
    return frames


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", nargs="?", choices=("echo", "noise", "unreachable", "drop", "delay"),
                        default="echo")
    parser.add_argument("--interface")
    parser.add_argument("--pcap")
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--delay", type=float, default=0.25)
    parser.add_argument("--check-pcap", metavar="FILE")
    args = parser.parse_args(argv)
    if args.check_pcap:
        try:
            check_pcap(args.check_pcap)
            return 0
        except (OSError, ValueError) as exc:
            parser.exit(1, f"error: {exc}\n")
    if not args.interface:
        parser.error("--interface is required")
    if args.count < 0 or args.delay < 0:
        parser.error("--count and --delay must be non-negative")
    try:
        serve(args, open_port(args.interface))
        return 0
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
