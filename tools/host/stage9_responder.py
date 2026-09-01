#!/usr/bin/env python3
"""Raw-Ethernet Stage 9 ARP, UDP echo and TFTP responder/capture."""

import argparse
import ipaddress
import os
import struct
import sys

from stage7_responder import PcapWriter, checksum, mac_bytes, open_port, parse_arp_request


ETH_IP = 0x0800
CLIENT_IP = ipaddress.IPv4Address("192.168.7.20").packed
SERVER_IP = ipaddress.IPv4Address("192.168.7.44").packed
SERVER_MAC = mac_bytes("02:00:00:00:00:44")
SERVER_TID = 0xBEEF
ECHO_PORT = 7777
TFTP_PORTS = (69, 6969)
GET_NAME = "S9GET.BIN"
PUT_NAME = "S9PUT.BIN"
GET_SIZE = 256 * 1024 + 123
PUT_SIZE = 1428 * 2


def fixture(size, salt):
    return bytes((index * 29 + (index >> 8) + salt) & 0xFF for index in range(size))


def write_fixtures(directory):
    os.makedirs(directory, exist_ok=True)
    paths = {
        GET_NAME: fixture(GET_SIZE, 0x39),
        PUT_NAME: fixture(PUT_SIZE, 0x71),
    }
    for name, data in paths.items():
        with open(os.path.join(directory, name), "wb") as output:
            output.write(data)
    print(f"READY fixtures={directory} get={GET_SIZE} put={PUT_SIZE}")


def parse_udp(frame):
    if len(frame) < 42 or struct.unpack_from("!H", frame, 12)[0] != ETH_IP:
        return None
    ip = frame[14:]
    if ip[0] != 0x45 or ip[9] != 17 or checksum(ip[:20]):
        return None
    total = struct.unpack_from("!H", ip, 2)[0]
    if total < 28 or total > 1500 or total > len(ip) or ip[6] & 0xBF or ip[7]:
        return None
    udp = ip[20:total]
    source_port, destination_port, length, supplied = struct.unpack_from("!HHHH", udp)
    if length != len(udp) or length < 8:
        return None
    pseudo = ip[12:20] + b"\0\x11" + struct.pack("!H", length)
    if supplied and checksum(pseudo + udp):
        return None
    return {
        "ether_source": frame[6:12], "source": ip[12:16], "destination": ip[16:20],
        "source_port": source_port, "destination_port": destination_port,
        "payload": udp[8:],
    }


def ipv4_udp(source, destination, source_port, destination_port, payload,
             identifier=0x6321):
    length = 8 + len(payload)
    udp = bytearray(struct.pack("!HHHH", source_port, destination_port, length, 0) + payload)
    pseudo = source + destination + b"\0\x11" + struct.pack("!H", length)
    value = checksum(pseudo + udp) or 0xFFFF
    struct.pack_into("!H", udp, 6, value)
    total = 20 + length
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, identifier,
                               0x4000, 63, 17, 0, source, destination))
    struct.pack_into("!H", ip, 10, checksum(bytes(ip)))
    return bytes(ip) + bytes(udp)


def udp_reply(request, source_port, payload, source_mac=SERVER_MAC):
    packet = ipv4_udp(request["destination"], request["source"], source_port,
                      request["source_port"], payload)
    return (request["ether_source"] + source_mac + struct.pack("!H", ETH_IP) +
            packet).ljust(60, b"\0")


def arp_reply(request):
    body = (b"\x00\x01\x08\x00\x06\x04\x00\x02" + SERVER_MAC +
            request["target"] + request["mac"] + request["ip"])
    return (request["mac"] + SERVER_MAC + struct.pack("!H", 0x0806) + body).ljust(60, b"\0")


def tftp_request(payload):
    if len(payload) < 4 or payload[:2] not in (b"\0\x01", b"\0\x02"):
        return None
    fields = payload[2:].split(b"\0")
    if not fields or fields[-1] != b"":
        return None
    fields.pop()
    if len(fields) not in (2, 4) or not fields[0] or len(fields[0]) > 79:
        return None
    if fields[1].lower() != b"octet":
        return None
    block_size = 512
    option = False
    if len(fields) == 4:
        if fields[2].lower() != b"blksize":
            return None
        try:
            block_size = int(fields[3].decode("ascii"), 10)
        except (UnicodeDecodeError, ValueError):
            return None
        if not 8 <= block_size <= 1428:
            return None
        option = True
    try:
        name = fields[0].decode("ascii")
    except UnicodeDecodeError:
        return None
    return {"opcode": payload[1], "name": name, "block_size": block_size, "option": option}


def tftp_data(block, data):
    return struct.pack("!HH", 3, block & 0xFFFF) + data


def tftp_ack(block):
    return struct.pack("!HH", 4, block & 0xFFFF)


def tftp_error(code, message):
    return struct.pack("!HH", 5, code) + message.encode("ascii", "replace")[:79] + b"\0"


class Responder:
    def __init__(self, profile="clean", upload_dir=None):
        self.profile = profile
        self.upload_dir = upload_dir
        self.files = {GET_NAME: fixture(GET_SIZE, 0x39)}
        self.sessions = {}
        self.events = []
        self.dropped = set()
        self.seen = {}

    @property
    def faults(self):
        return self.profile == "faults"

    def event(self, text):
        self.events.append(text)

    def packet(self, request, payload, port=SERVER_TID):
        return udp_reply(request, port, payload)

    def data_for(self, session, block):
        start = (block - 1) * session["block_size"]
        return session["data"][start:start + session["block_size"]]

    def data_packet(self, session, block):
        data = self.data_for(session, block)
        if len(data) < session["block_size"]:
            session["final_block"] = block
        return tftp_data(block, data)

    def maybe_drop(self, key, label):
        if not self.faults or key in self.dropped:
            return False
        self.dropped.add(key)
        self.event(f"DROP {label}")
        return True

    def note_retry(self, key, label):
        count = self.seen.get(key, 0) + 1
        self.seen[key] = count
        if count > 1:
            self.event(f"RETRY {label} count={count}")

    def tftp_frames(self, request):
        payload = request["payload"]
        parsed = tftp_request(payload)
        if parsed and request["destination_port"] in TFTP_PORTS:
            key = (request["source_port"], parsed["opcode"], parsed["name"])
            self.note_retry(key, f"request name={parsed['name']}")
            if request["destination_port"] == 6969 and self.maybe_drop(
                    ("request", key), f"TFTP request name={parsed['name']}"):
                return []
            if parsed["opcode"] == 1:
                data = self.files.get(parsed["name"].upper())
                if data is None:
                    return [self.packet(request, tftp_error(1, "File not found"))]
                session = {"mode": "get", "name": parsed["name"], "data": data,
                           "block_size": parsed["block_size"]}
                self.sessions[request["source_port"]] = session
                self.event(f"TFTP RRQ name={parsed['name']} blksize={parsed['block_size']}")
                if parsed["option"]:
                    return [self.packet(request, b"\0\x06blksize\0" +
                                        str(parsed["block_size"]).encode("ascii") + b"\0")]
                return [self.packet(request, self.data_packet(session, 1))]
            session = {"mode": "put", "name": parsed["name"], "chunks": [], "expected": 1,
                       "block_size": parsed["block_size"]}
            self.sessions[request["source_port"]] = session
            self.event(f"TFTP WRQ name={parsed['name']} blksize={parsed['block_size']}")
            if parsed["option"]:
                return [self.packet(request, b"\0\x06blksize\0" +
                                    str(parsed["block_size"]).encode("ascii") + b"\0")]
            return [self.packet(request, tftp_ack(0))]

        session = self.sessions.get(request["source_port"])
        if not session or request["destination_port"] != SERVER_TID or len(payload) < 4:
            return []
        opcode, block = struct.unpack_from("!HH", payload)
        if opcode == 4 and len(payload) == 4 and session["mode"] == "get":
            self.note_retry((request["source_port"], opcode, block), f"ACK block={block}")
            if session.get("final_block") == block:
                self.event(f"TFTP GET complete name={session['name']} block={block}")
                return []
            next_block = (block + 1) & 0xFFFF
            body = self.data_packet(session, next_block)
            if next_block == 2 and self.maybe_drop(("get-data", next_block),
                                                   f"DATA block={next_block}"):
                return []
            frames = []
            if self.faults and next_block == 1:
                frames.append(self.packet(request, body, (SERVER_TID + 1) & 0xFFFF))
                self.event("TFTP unknown-TID DATA block=1")
            if self.faults and next_block == 2:
                future = (next_block + 1) & 0xFFFF
                frames.append(self.packet(request, tftp_data(future, self.data_for(session, future))))
                self.event(f"TFTP reorder DATA block={future}")
            frames.append(self.packet(request, body))
            if self.faults and next_block in (1, 3):
                frames.append(self.packet(request, body))
                self.event(f"TFTP duplicate DATA block={next_block}")
            return frames
        if opcode == 3 and session["mode"] == "put":
            data = payload[4:]
            self.note_retry((request["source_port"], opcode, block), f"DATA block={block}")
            if block == session["expected"]:
                session["chunks"].append(data)
                session["expected"] = (session["expected"] + 1) & 0xFFFF
                if len(data) < session["block_size"]:
                    upload = b"".join(session["chunks"])
                    self.files[session["name"].upper()] = upload
                    self.event(f"TFTP PUT complete name={session['name']} bytes={len(upload)}")
                    if self.upload_dir:
                        os.makedirs(self.upload_dir, exist_ok=True)
                        with open(os.path.join(self.upload_dir, os.path.basename(session["name"])), "wb") as out:
                            out.write(upload)
            previous = (session["expected"] - 1) & 0xFFFF
            if block != previous:
                return []
            if block == 2 and self.maybe_drop(("put-ack", block), f"ACK block={block}"):
                return []
            frames = [self.packet(request, tftp_ack(block))]
            if self.faults and block == 1:
                frames.append(self.packet(request, tftp_ack(block)))
                self.event("TFTP duplicate ACK block=1")
            return frames
        return []

    def handle(self, frame):
        arp = parse_arp_request(frame)
        if arp and arp["target"] == SERVER_IP:
            return [("ARP", arp_reply(arp))]
        request = parse_udp(frame)
        if not request or request["source"] != CLIENT_IP or request["destination"] != SERVER_IP:
            return []
        if request["destination_port"] == ECHO_PORT:
            return [("UDP", self.packet(request, request["payload"], ECHO_PORT))]
        return [("TFTP", item) for item in self.tftp_frames(request)]


def serve(args, port):
    capture = PcapWriter(args.pcap)
    responder = Responder(args.profile, args.upload_dir)
    sent = 0
    try:
        print(f"READY interface={args.interface} profile={args.profile} "
              f"udp={ECHO_PORT} tftp=69,6969 tid={SERVER_TID}", flush=True)
        while not args.count or sent < args.count:
            frame = port.receive()
            arp = parse_arp_request(frame)
            udp = parse_udp(frame)
            if arp or udp:
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
    frames = udp_frames = tftp_frames = 0
    echo_requests = {}
    echo_replies = get_data = put_data = 0
    sessions = {}
    transfers = {}
    get_blocks = {}
    put_blocks = {}
    expected_get = fixture(GET_SIZE, 0x39)
    expected_put = fixture(PUT_SIZE, 0x71)
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap record header")
        _sec, _usec, captured, wire = struct.unpack_from("<IIII", data, offset)
        offset += 16
        if captured != wire or not 42 <= captured <= 1514 or offset + captured > len(data):
            raise ValueError("invalid captured/wire length or truncated frame")
        frame = data[offset:offset + captured]
        offset += captured
        ether_type = struct.unpack_from("!H", frame, 12)[0]
        if ether_type == 0x0806:
            if frame[14:20] != b"\0\x01\x08\0\x06\x04" or frame[20:22] not in (
                    b"\0\x01", b"\0\x02") or any(frame[42:]):
                raise ValueError("malformed ARP frame/padding")
        elif ether_type == ETH_IP:
            udp = parse_udp(frame)
            if not udp:
                raise ValueError("malformed IPv4/UDP checksum or length")
            total = struct.unpack_from("!H", frame, 16)[0]
            if any(frame[14 + total:]):
                raise ValueError("nonzero Ethernet padding after IPv4 total length")
            udp_frames += 1
            if udp["destination_port"] == ECHO_PORT and udp["source"] == CLIENT_IP:
                echo_requests[udp["source_port"]] = udp["payload"]
            elif udp["source_port"] == ECHO_PORT and udp["destination"] == CLIENT_IP:
                if echo_requests.get(udp["destination_port"]) != udp["payload"]:
                    raise ValueError("UDP echo payload/port is not byte-exact")
                echo_replies += 1
            if udp["source_port"] in TFTP_PORTS + (SERVER_TID, SERVER_TID + 1) or \
                    udp["destination_port"] in TFTP_PORTS + (SERVER_TID, SERVER_TID + 1):
                if len(udp["payload"]) < 2 or udp["payload"][0] != 0 or not 1 <= udp["payload"][1] <= 6:
                    raise ValueError("malformed TFTP opcode")
                tftp_frames += 1
                request = tftp_request(udp["payload"])
                if request and udp["destination_port"] in TFTP_PORTS:
                    session = {
                        "mode": "get" if request["opcode"] == 1 else "put",
                        "name": request["name"].upper(), "block_size": request["block_size"],
                    }
                    sessions[udp["source_port"]] = session
                    transfers[session["mode"]] = session
                elif len(udp["payload"]) >= 4 and udp["payload"][1] == 3:
                    block = struct.unpack_from("!H", udp["payload"], 2)[0]
                    session_port = (udp["destination_port"] if udp["source_port"] in
                                    (SERVER_TID, SERVER_TID + 1) else udp["source_port"])
                    session = sessions.get(session_port)
                    if not session:
                        raise ValueError("TFTP DATA has no captured request session")
                    if session["mode"] == "get":
                        if session["name"] != GET_NAME:
                            raise ValueError("unexpected GET fixture name")
                        expected_file = expected_get
                        get_data += 1
                        if udp["source_port"] == SERVER_TID:
                            previous = get_blocks.setdefault(block, udp["payload"][4:])
                            if previous != udp["payload"][4:]:
                                raise ValueError(f"conflicting TFTP GET DATA block {block}")
                    else:
                        if session["name"] != PUT_NAME:
                            raise ValueError("unexpected PUT fixture name")
                        expected_file = expected_put
                        put_data += 1
                        if udp["destination_port"] == SERVER_TID:
                            previous = put_blocks.setdefault(block, udp["payload"][4:])
                            if previous != udp["payload"][4:]:
                                raise ValueError(f"conflicting TFTP PUT DATA block {block}")
                    start = (block - 1) * session["block_size"]
                    expected = expected_file[start:start + session["block_size"]]
                    if udp["payload"][4:] != expected:
                        raise ValueError(f"TFTP DATA block {block} is not byte-exact")
        else:
            raise ValueError("unexpected EtherType")
        frames += 1
    if not frames or not udp_frames or not tftp_frames or not echo_replies or not get_data or not put_data:
        raise ValueError("pcap lacks required UDP echo and TFTP GET/PUT data")

    def require_complete(mode, expected, blocks):
        session = transfers.get(mode)
        if not session:
            raise ValueError(f"pcap lacks a TFTP {mode.upper()} request")
        block_size = session["block_size"]
        count = len(expected) // block_size + 1
        rebuilt = bytearray()
        for block in range(1, count + 1):
            if block not in blocks:
                raise ValueError(f"pcap lacks TFTP {mode.upper()} DATA block {block}")
            rebuilt.extend(blocks[block])
        if bytes(rebuilt) != expected or len(blocks[count]) >= block_size:
            raise ValueError(f"pcap TFTP {mode.upper()} transfer is incomplete")

    require_complete("get", expected_get, get_blocks)
    require_complete("put", expected_put, put_blocks)
    print(f"PCAP OK frames={frames} udp={udp_frames} tftp={tftp_frames} "
          f"echo={echo_replies} get-data={get_data} put-data={put_data} "
          "byte-exact no-fcs-record-lengths=exact")
    return frames


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface")
    parser.add_argument("--pcap")
    parser.add_argument("--profile", choices=("clean", "faults"), default="clean")
    parser.add_argument("--upload-dir")
    parser.add_argument("--count", type=int, default=0)
    parser.add_argument("--check-pcap", metavar="FILE")
    parser.add_argument("--prepare-fixtures", metavar="DIR")
    args = parser.parse_args(argv)
    if args.prepare_fixtures:
        write_fixtures(args.prepare_fixtures)
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
        serve(args, open_port(args.interface))
        return 0
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
