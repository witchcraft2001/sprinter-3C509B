#!/usr/bin/env python3
"""Stage 11 raw two-channel TCP echo responder and classic-pcap checker."""

import argparse
import ipaddress
import struct
import sys

import stage7_responder as stage7


CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
SERVICE_IP = ipaddress.IPv4Address("192.168.7.44").packed
CLIENT_MAC = bytes.fromhex("02608c123456")
SERVER_MAC = bytes.fromhex("020000000044")
TCP_PORT = 7777
TCP_MSS = 536


def parse_tcp(frame):
    if len(frame) < 54 or frame[12:14] != b"\x08\x00" or frame[14] != 0x45:
        return None
    total = struct.unpack_from("!H", frame, 16)[0]
    if total < 40 or total > 1500 or 14 + total > len(frame):
        return None
    ip_header = frame[14:34]
    if ip_header[9] != 6 or ip_header[6] & 0xBF or ip_header[7]:
        return None
    if stage7.checksum(ip_header):
        return None
    segment = frame[34:14 + total]
    header_length = (segment[12] >> 4) * 4
    if header_length < 20 or header_length > len(segment) or segment[12] & 0x0F:
        return None
    pseudo = ip_header[12:20] + b"\0\x06" + struct.pack("!H", len(segment)) + segment
    if stage7.checksum(pseudo):
        return None
    source_port, destination_port = struct.unpack_from("!HH", segment)
    if not source_port or not destination_port:
        return None
    mss = 0
    offset = 20
    while offset < header_length:
        kind = segment[offset]
        if kind == 0:
            break
        if kind == 1:
            offset += 1
            continue
        if offset + 1 >= header_length:
            return None
        length = segment[offset + 1]
        if length < 2 or offset + length > header_length:
            return None
        if kind == 2 and length == 4:
            mss = struct.unpack_from("!H", segment, offset + 2)[0]
        offset += length
    return {
        "ether_source": frame[6:12], "source": ip_header[12:16],
        "destination": ip_header[16:20],
        "source_port": source_port, "destination_port": destination_port,
        "sequence": struct.unpack_from("!I", segment, 4)[0],
        "acknowledgement": struct.unpack_from("!I", segment, 8)[0],
        "flags": segment[13], "window": struct.unpack_from("!H", segment, 14)[0],
        "mss": mss, "payload": segment[header_length:],
    }


def build_tcp(request, sequence, acknowledgement, flags, payload=b"", window=4096,
              mss=TCP_MSS):
    options = b"\x02\x04" + struct.pack("!H", mss) if flags & 2 else b""
    header_length = 20 + len(options)
    segment = bytearray(struct.pack(
        "!HHIIBBHHH", request["destination_port"], request["source_port"],
        sequence & 0xFFFFFFFF, acknowledgement & 0xFFFFFFFF,
        (header_length // 4) << 4, flags, window, 0, 0) + options + payload)
    pseudo = (request["destination"] + request["source"] + b"\0\x06" +
              struct.pack("!H", len(segment)) + segment)
    struct.pack_into("!H", segment, 16, stage7.checksum(pseudo))
    total = 20 + len(segment)
    ip_header = bytearray(struct.pack(
        "!BBHHHBBH4s4s", 0x45, 0, total, 0x5111, 0x4000, 62, 6, 0,
        request["destination"], request["source"]))
    struct.pack_into("!H", ip_header, 10, stage7.checksum(ip_header))
    frame = bytearray(request["ether_source"] + SERVER_MAC + b"\x08\x00" +
                      ip_header + segment)
    frame.extend(b"\0" * max(0, 60 - len(frame)))
    return bytes(frame)


class Responder:
    def __init__(self, profile="clean"):
        self.profile = profile
        self.connections = {}
        self.events = []
        self.syn_count = 0
        self.data_count = 0
        self.reset_injected = False

    def event(self, message):
        self.events.append(message)

    def handle(self, frame):
        arp = stage7.parse_arp_request(frame)
        if arp and arp["target"] == SERVICE_IP:
            self.event("ARP service")
            return [("ARP", stage7.build_arp_reply(arp, SERVER_MAC))]
        request = parse_tcp(frame)
        if (not request or request["source"] != CLIENT_IP or
                request["destination"] != SERVICE_IP or
                request["destination_port"] != TCP_PORT):
            return []
        key = (request["source"], request["source_port"])
        if request["flags"] & 4:
            self.connections.pop(key, None)
            self.event(f"RST client-port={request['source_port']}")
            return []
        if request["flags"] & 2:
            self.syn_count += 1
            if self.profile == "faults" and self.syn_count == 1:
                self.event("DROP first SYN")
                return []
            connection = self.connections.get(key)
            client_next = (request["sequence"] + 1) & 0xFFFFFFFF
            if connection is None or connection["client_next"] != client_next:
                server_isn = (0x10203040 + len(self.connections) * 0x10000) & 0xFFFFFFFF
                window = 0 if self.profile == "zero" else 4096
                connection = {"server_isn": server_isn,
                              "server_next": (server_isn + 1) & 0xFFFFFFFF,
                              "server_acked": (server_isn + 1) & 0xFFFFFFFF,
                              "client_next": client_next,
                              "pending": bytearray(), "window": request["window"],
                              "advertised_window": window, "probe_count": 0,
                              "fault_sent": False, "established": False}
                self.connections[key] = connection
            self.event(f"SYN channel={request['source_port']} mss={request['mss']}")
            return [("SYNACK", build_tcp(request, connection["server_isn"],
                                          connection["client_next"], 0x12,
                                          window=connection["advertised_window"]))]
        connection = self.connections.get(key)
        if connection is None:
            return [("RST", build_tcp(request, 0, 0, 0x04, window=0))]
        connection["window"] = request["window"]
        if request["flags"] & 0x10:
            acknowledged = ((request["acknowledgement"] -
                             connection["server_acked"]) & 0xFFFFFFFF)
            outstanding = ((connection["server_next"] -
                            connection["server_acked"]) & 0xFFFFFFFF)
            if acknowledged <= outstanding:
                connection["server_acked"] = request["acknowledgement"]
        if (not connection["established"] and not request["payload"] and
                not request["flags"] & 1 and
                request["acknowledgement"] == connection["server_next"]):
            connection["established"] = True
            self.event(f"ESTABLISHED channel={request['source_port']}")
            return []
        if (self.profile == "zero" and request["payload"] and
                request["sequence"] == ((connection["client_next"] - 1) &
                                        0xFFFFFFFF)):
            connection["probe_count"] += 1
            if connection["probe_count"] >= 3:
                connection["advertised_window"] = 4096
            self.event(f"WINDOW probe={connection['probe_count']}")
            return [("WINDOW", build_tcp(
                request, connection["server_next"], connection["client_next"],
                0x10, window=connection["advertised_window"]))]
        accepted = False
        if request["payload"]:
            self.data_count += 1
            if self.profile == "reset" and not self.reset_injected:
                self.reset_injected = True
                self.event("RST injected")
                return [("RST", build_tcp(request, connection["server_next"],
                                           connection["client_next"], 0x14, window=0))]
            if request["sequence"] == connection["client_next"]:
                connection["client_next"] = ((connection["client_next"] +
                                               len(request["payload"])) & 0xFFFFFFFF)
                connection["pending"].extend(request["payload"])
                accepted = True
                if self.profile == "faults" and self.data_count == 1:
                    self.event("DROP first data ACK")
                    return []
        if request["flags"] & 1:
            connection["client_next"] = (connection["client_next"] + 1) & 0xFFFFFFFF
            self.event(f"FIN channel={request['source_port']}")
            return [("FIN", build_tcp(request, connection["server_next"],
                                       connection["client_next"], 0x11,
                                       window=connection["advertised_window"]))]
        in_flight = ((connection["server_next"] -
                     connection["server_acked"]) & 0xFFFFFFFF)
        available = max(0, connection["window"] - in_flight)
        if connection["pending"] and available:
            size = min(TCP_MSS, available, len(connection["pending"]))
            payload = bytes(connection["pending"][:size])
            del connection["pending"][:size]
            replies = []
            if self.profile == "faults" and not connection["fault_sent"]:
                connection["fault_sent"] = True
                replies.append(("OUT-OF-ORDER", build_tcp(
                    request, connection["server_next"] + size,
                    connection["client_next"], 0x18, payload,
                    window=connection["advertised_window"])))
            reply = build_tcp(request, connection["server_next"],
                              connection["client_next"], 0x18, payload,
                              window=connection["advertised_window"])
            replies.append(("DATA", reply))
            if self.profile == "faults":
                replies.append(("DUPLICATE", reply))
            connection["server_next"] = ((connection["server_next"] + size) &
                                          0xFFFFFFFF)
            self.event(f"DATA channel={request['source_port']} bytes={size}")
            return replies
        if accepted or request["payload"]:
            return [("ACK", build_tcp(request, connection["server_next"],
                                       connection["client_next"], 0x10,
                                       window=connection["advertised_window"]))]
        return []


def serve(args, port):
    capture = stage7.PcapWriter(args.pcap)
    responder = Responder(args.profile)
    sent = 0
    try:
        print(f"READY interface={args.interface} profile={args.profile} "
              f"tcp={TCP_PORT} mss={TCP_MSS}", flush=True)
        while not args.count or sent < args.count:
            frame = port.receive()
            if stage7.parse_arp_request(frame) or parse_tcp(frame):
                capture.write(frame)
            for label, reply in responder.handle(frame):
                port.send(reply)
                capture.write(reply)
                sent += 1
                print(f"FRAME {sent} {label} bytes={len(reply)}", flush=True)
            while responder.events:
                print(responder.events.pop(0), flush=True)
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
    frames = []
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap record header")
        _sec, _usec, captured, wire = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if captured != wire or not 42 <= captured <= 1514 or offset + captured > len(data):
            raise ValueError("invalid classic-pcap record")
        frame = data[offset:offset + captured]
        offset += captured
        if frame[12:14] == b"\x08\x00":
            parsed = parse_tcp(frame)
            if parsed is None:
                raise ValueError("malformed TCP/IP frame")
            frames.append(parsed)
    client = [item for item in frames if item["source"] == CLIENT_IP]
    syns = [item for item in client if item["flags"] & 2]
    data_frames = [item for item in client if item["payload"] and item["flags"] & 0x08]
    closes = [item for item in client if item["flags"] & (1 | 4)]
    if len({item["source_port"] for item in syns}) < 2:
        raise ValueError("pcap lacks two client TCP channels")
    if len({item["source_port"] for item in data_frames}) < 2:
        raise ValueError("pcap lacks client data on both TCP channels")
    if len({item["source_port"] for item in closes}) < 2:
        raise ValueError("pcap lacks close evidence for both TCP channels")
    if any(item["mss"] != TCP_MSS for item in syns):
        raise ValueError("client SYN does not advertise MSS 536")
    if any(len(item["payload"]) > TCP_MSS for item in data_frames):
        raise ValueError("client data exceeds MSS 536")
    print(f"PCAP OK tcp={len(frames)} channels={len(set(item['source_port'] for item in syns))} "
          f"data={sum(len(item['payload']) for item in data_frames)} mss={TCP_MSS} "
          "checksums=valid")
    return frames


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface")
    parser.add_argument("--pcap")
    parser.add_argument("--profile", choices=("clean", "faults", "zero", "reset"),
                        default="clean")
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--check-pcap", metavar="FILE")
    args = parser.parse_args(argv)
    if args.check_pcap:
        try:
            check_pcap(args.check_pcap)
            return 0
        except (OSError, ValueError) as exc:
            parser.exit(1, f"error: {exc}\n")
    if not args.interface or not args.pcap:
        parser.error("--interface and --pcap are required")
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
