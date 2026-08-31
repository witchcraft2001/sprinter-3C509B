#!/usr/bin/env python3
"""Pure standard-library frame tests for the Stage 7 responder."""

import struct
from types import SimpleNamespace

import stage7_responder as responder


class FakePort:
    def __init__(self, frames):
        self.frames = iter(frames)
        self.sent = []
        self.closed = False

    def receive(self):
        return next(self.frames)

    def send(self, frame):
        self.sent.append(frame)

    def close(self):
        self.closed = True


def make_request(message_type):
    request = {"xid": b"\x12\x34\x56\x78", "mac": b"\x02\x60\x8c\x12\x34\x56",
               "type": message_type, "options": {53: bytes((message_type,))}}
    reply = responder.build_dhcp_reply(
        request, 2 if message_type == 1 else 5,
        b"\x02\0\0\0\0\1", bytes((192, 168, 77, 1)), bytes((192, 168, 77, 20)),
        bytes((255, 255, 255, 0)), bytes((192, 168, 77, 1)),
        bytes((1, 1, 1, 1, 8, 8, 8, 8)), 86400)
    ip = reply[14:34]
    udp = reply[34:]
    assert responder.checksum(ip) == 0
    assert responder.udp_ipv4(ip[12:16], ip[16:20], udp[:6] + b"\0\0" + udp[8:]) == struct.unpack_from("!H", udp, 6)[0]
    return reply


def client_from_reply(reply, message_type):
    server_ip = reply[26:30]
    offered = reply[50:54]
    mac = reply[70:76]
    bootp = bytearray(240)
    bootp[:4] = b"\x01\x01\x06\x00"
    bootp[4:8] = b"\x12\x34\x56\x78"
    bootp[28:34] = mac
    bootp[236:240] = b"\x63\x82\x53\x63"
    options = bytes((53, 1, message_type, 50, 4)) + offered + bytes((54, 4)) + server_ip + b"\xff"
    payload = bytes(bootp) + options
    udp = bytearray(struct.pack("!HHHH", 68, 67, len(payload) + 8, 0) + payload)
    source = b"\0" * 4
    destination = b"\xff" * 4
    struct.pack_into("!H", udp, 6, responder.udp_ipv4(source, destination, bytes(udp)))
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 1, 0, 64, 17, 0, source, destination))
    struct.pack_into("!H", ip, 10, responder.checksum(bytes(ip)))
    return b"\xff" * 6 + mac + struct.pack("!H", responder.ETH_IP) + bytes(ip) + bytes(udp)


def main():
    offer = make_request(1)
    request = client_from_reply(offer, 3)
    parsed = responder.parse_dhcp(request)
    assert parsed and parsed["type"] == 3 and parsed["xid"] == b"\x12\x34\x56\x78"
    ack = make_request(3)
    assert responder.parse_options(ack[14 + 20 + 8 + 240:]) is not None
    damaged = bytearray(request); damaged[24] ^= 1
    assert responder.parse_dhcp(bytes(damaged)) is None

    client_mac = b"\x02\x60\x8c\x12\x34\x56"
    client_ip = bytes((192, 168, 77, 20))
    target = bytes((192, 168, 77, 1))
    arp = b"\xff" * 6 + client_mac + struct.pack("!H", responder.ETH_ARP)
    arp += b"\x00\x01\x08\x00\x06\x04\x00\x01" + client_mac + client_ip + b"\0" * 6 + target
    parsed_arp = responder.parse_arp_request(arp)
    reply = responder.build_arp_reply(parsed_arp, b"\x02\0\0\0\0\1")
    assert len(reply) == 60 and reply[20:22] == b"\0\x02" and reply[38:42] == client_ip
    assert reply[42:] == b"\0" * 18
    # macOS exposes timeval32 in bpf_hdr even to LP64 processes: caplen starts
    # at byte 8, hdrlen at byte 16, and each complete record is 4-byte aligned.
    bpf_header = struct.pack("=iiIIH", 1, 2, len(arp), len(arp), 18)
    bpf_record = bpf_header + arp
    bpf_record += b"\0" * ((-len(bpf_record)) & 3)
    assert responder.decode_bpf_records(bpf_record) == [arp]

    # The deterministic retry mode drops the first DISCOVER, replies to the
    # retransmission, and then ACKs REQUEST. This avoids a manual timing race
    # in the MAME acceptance procedure.
    discover = client_from_reply(offer, 1)
    port = FakePort((discover, discover, request))
    args = SimpleNamespace(
        pcap=None, count=2, interface="fake0", arp="reply", dhcp="ack",
        ignore_dhcp=1, server_mac=b"\x02\0\0\0\0\1",
        server_ip=bytes((192, 168, 77, 1)), offer_ip=bytes((192, 168, 77, 20)),
        mask=bytes((255, 255, 255, 0)), router=bytes((192, 168, 77, 1)),
        dns=bytes((192, 168, 77, 1)), lease=86400)
    assert responder.serve(args, port) == 2
    assert port.closed and len(port.sent) == 2
    assert [responder.parse_options(frame[14 + 20 + 8 + 240:])[53]
            for frame in port.sent] == [b"\x02", b"\x05"]
    print("Stage 7 responder: exact ARP and DHCP framing/checksums passed")


if __name__ == "__main__":
    main()
