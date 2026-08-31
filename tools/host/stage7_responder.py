#!/usr/bin/env python3
"""Small ARP/DHCP responder and classic-pcap recorder for Stage 7 acceptance."""

import argparse
import fcntl
import ipaddress
import os
import platform
import select
import socket
import struct
import sys
import time


ETH_ARP = 0x0806
ETH_IP = 0x0800


def mac_bytes(text):
    try:
        value = bytes(int(part, 16) for part in text.split(":"))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("invalid MAC") from exc
    if len(value) != 6 or any(len(part) != 2 for part in text.split(":")):
        raise argparse.ArgumentTypeError("MAC must contain six two-digit bytes")
    return value


def ip_bytes(text):
    try:
        return ipaddress.IPv4Address(text).packed
    except ipaddress.AddressValueError as exc:
        raise argparse.ArgumentTypeError("invalid IPv4 address") from exc


def checksum(data):
    if len(data) & 1:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def udp_ipv4(source, destination, udp):
    pseudo = source + destination + b"\0\x11" + struct.pack("!H", len(udp))
    value = checksum(pseudo + udp)
    return value or 0xFFFF


def parse_options(data):
    result = {}
    offset = 0
    while offset < len(data):
        code = data[offset]
        offset += 1
        if code == 0:
            continue
        if code == 255:
            return result
        if offset >= len(data):
            return None
        length = data[offset]
        offset += 1
        if offset + length > len(data):
            return None
        result[code] = data[offset:offset + length]
        offset += length
    return None


def parse_dhcp(frame):
    if len(frame) < 14 + 20 + 8 + 240 or struct.unpack_from("!H", frame, 12)[0] != ETH_IP:
        return None
    ip = frame[14:]
    ihl = (ip[0] & 15) * 4
    if ip[0] >> 4 != 4 or ihl != 20 or len(ip) < ihl + 8:
        return None
    total = struct.unpack_from("!H", ip, 2)[0]
    if total < ihl + 8 + 240 or total > len(ip) or ip[9] != 17 or checksum(ip[:ihl]):
        return None
    udp = ip[ihl:total]
    source_port, destination_port, length, supplied = struct.unpack_from("!HHHH", udp)
    if (source_port, destination_port) != (68, 67) or length != len(udp):
        return None
    if supplied and udp_ipv4(ip[12:16], ip[16:20], udp[:6] + b"\0\0" + udp[8:]) != supplied:
        return None
    bootp = udp[8:]
    if bootp[0] != 1 or bootp[1] != 1 or bootp[2] != 6 or bootp[236:240] != b"\x63\x82\x53\x63":
        return None
    options = parse_options(bootp[240:])
    if options is None or 53 not in options or len(options[53]) != 1:
        return None
    return {"xid": bootp[4:8], "mac": bootp[28:34], "type": options[53][0], "options": options}


def build_dhcp_reply(request, reply_type, server_mac, server_ip, offered_ip,
                     mask, router, dns, lease):
    yiaddr = b"\0" * 4 if reply_type == 6 else offered_ip
    bootp = bytearray(240)
    bootp[0:4] = b"\x02\x01\x06\x00"
    bootp[4:8] = request["xid"]
    bootp[16:20] = yiaddr
    bootp[20:24] = server_ip
    bootp[28:34] = request["mac"]
    bootp[236:240] = b"\x63\x82\x53\x63"
    options = bytearray((53, 1, reply_type, 54, 4)) + server_ip
    if reply_type != 6:
        options += bytearray((1, 4)) + mask
        options += bytearray((3, 4)) + router
        options += bytearray((6, len(dns))) + dns
        options += bytearray((51, 4)) + struct.pack("!I", lease)
    options.append(255)
    payload = bytes(bootp) + bytes(options)
    udp_length = 8 + len(payload)
    udp = bytearray(struct.pack("!HHHH", 67, 68, udp_length, 0) + payload)
    struct.pack_into("!H", udp, 6, udp_ipv4(server_ip, b"\xff" * 4, bytes(udp)))
    total = 20 + len(udp)
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, 0, 0,
                               64, 17, 0, server_ip, b"\xff" * 4))
    struct.pack_into("!H", ip, 10, checksum(bytes(ip)))
    return b"\xff" * 6 + server_mac + struct.pack("!H", ETH_IP) + bytes(ip) + bytes(udp)


def parse_arp_request(frame):
    if len(frame) < 42 or struct.unpack_from("!H", frame, 12)[0] != ETH_ARP:
        return None
    arp = frame[14:42]
    if arp[:8] != b"\x00\x01\x08\x00\x06\x04\x00\x01":
        return None
    return {"mac": arp[8:14], "ip": arp[14:18], "target": arp[24:28]}


def build_arp_reply(request, server_mac):
    arp = (b"\x00\x01\x08\x00\x06\x04\x00\x02" + server_mac +
           request["target"] + request["mac"] + request["ip"])
    frame = request["mac"] + server_mac + struct.pack("!H", ETH_ARP) + arp
    # Ethernet requires 60 bytes before the FCS. A physical NIC normally adds
    # this padding, but raw BPF/AF_PACKET injection bypasses that service and
    # the emulated 3C509B correctly rejects a 42-byte runt frame.
    return frame.ljust(60, b"\0")


class PcapWriter:
    def __init__(self, path):
        self.output = open(path, "wb") if path else None
        if self.output:
            self.output.write(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
            self.output.flush()

    def write(self, frame):
        if not self.output:
            return
        now = time.time()
        seconds = int(now)
        usec = int((now - seconds) * 1_000_000)
        self.output.write(struct.pack("<IIII", seconds, usec, len(frame), len(frame)))
        self.output.write(frame)
        self.output.flush()

    def close(self):
        if self.output:
            self.output.close()


class LinuxPort:
    def __init__(self, interface):
        self.raw = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(3))
        self.raw.bind((interface, 0))

    def receive(self):
        return self.raw.recv(65535)

    def send(self, frame):
        self.raw.send(frame)

    def close(self):
        self.raw.close()


def decode_bpf_records(data):
    """Decode macOS BPF records (timeval32 + caplen/datalen/hdrlen)."""
    frames = []
    offset = 0
    minimum_header = 18
    while offset + minimum_header <= len(data):
        caplen, _wire, hdrlen = struct.unpack_from("=IIH", data, offset + 8)
        if hdrlen < minimum_header:
            raise ValueError(f"invalid BPF header length {hdrlen}")
        start = offset + hdrlen
        end = start + caplen
        if end > len(data):
            raise ValueError("truncated BPF record")
        frames.append(data[start:end])
        offset = (end + 3) & ~3
    return frames


class BpfPort:
    def __init__(self, interface):
        self.fd = None
        for number in range(256):
            try:
                self.fd = os.open(f"/dev/bpf{number}", os.O_RDWR)
                break
            except OSError:
                pass
        if self.fd is None:
            raise OSError("no writable /dev/bpf device")
        try:
            fcntl.ioctl(self.fd, 0x8020426C, struct.pack("16s16x", interface.encode("ascii")))
            fcntl.ioctl(self.fd, 0x80044275, struct.pack("I", 1))  # BIOCSHDRCMPLT
            fcntl.ioctl(self.fd, 0x80044270, struct.pack("I", 1))  # BIOCIMMEDIATE
            length = fcntl.ioctl(self.fd, 0x40044266, struct.pack("I", 0))
            self.length = struct.unpack("I", length)[0]
            self.pending = []
        except Exception:
            os.close(self.fd)
            raise

    def receive(self):
        while not self.pending:
            data = os.read(self.fd, self.length)
            self.pending.extend(decode_bpf_records(data))
        return self.pending.pop(0)

    def send(self, frame):
        if os.write(self.fd, frame) != len(frame):
            raise OSError("short BPF write")

    def close(self):
        os.close(self.fd)


def open_port(interface):
    system = platform.system()
    if system == "Linux":
        return LinuxPort(interface)
    if system == "Darwin":
        return BpfPort(interface)
    raise OSError(f"raw Ethernet is unsupported on {system}")


def serve(args, port):
    capture = PcapWriter(args.pcap)
    responses = 0
    ignored_dhcp = 0
    try:
        print(f"READY interface={args.interface} arp={args.arp} dhcp={args.dhcp}", flush=True)
        while not args.count or responses < args.count:
            frame = port.receive()
            reply = None
            arp = parse_arp_request(frame)
            dhcp = parse_dhcp(frame)
            if arp and args.arp == "reply" and arp["target"] == args.server_ip:
                reply = build_arp_reply(arp, args.server_mac)
            elif dhcp:
                if ignored_dhcp < args.ignore_dhcp:
                    ignored_dhcp += 1
                    print(f"DROP {ignored_dhcp} DHCP", flush=True)
                elif args.dhcp != "drop":
                    if dhcp["type"] == 1:
                        reply = build_dhcp_reply(dhcp, 2, args.server_mac, args.server_ip,
                                                 args.offer_ip, args.mask, args.router,
                                                 args.dns, args.lease)
                    elif dhcp["type"] == 3:
                        kind = 6 if args.dhcp == "nak" else 5
                        reply = build_dhcp_reply(dhcp, kind, args.server_mac, args.server_ip,
                                                 args.offer_ip, args.mask, args.router,
                                                 args.dns, args.lease)
            if arp or dhcp:
                capture.write(frame)
            if reply:
                port.send(reply)
                capture.write(reply)
                responses += 1
                print(f"FRAME {responses} {'ARP' if arp else 'DHCP'}", flush=True)
    finally:
        capture.close()
        port.close()
    return responses


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interface", required=True)
    parser.add_argument("--server-mac", type=mac_bytes, default=mac_bytes("02:00:00:00:00:01"))
    parser.add_argument("--server-ip", type=ip_bytes, default=ip_bytes("192.168.77.1"))
    parser.add_argument("--offer-ip", type=ip_bytes, default=ip_bytes("192.168.77.20"))
    parser.add_argument("--mask", type=ip_bytes, default=ip_bytes("255.255.255.0"))
    parser.add_argument("--router", type=ip_bytes, default=ip_bytes("192.168.77.1"))
    parser.add_argument("--dns", type=ip_bytes, action="append")
    parser.add_argument("--lease", type=int, default=86400)
    parser.add_argument("--dhcp", choices=("ack", "nak", "drop"), default="ack")
    parser.add_argument("--ignore-dhcp", type=int, default=0,
                        help="capture and ignore this many client DHCP frames before replying")
    parser.add_argument("--arp", choices=("reply", "drop"), default="reply")
    parser.add_argument("--pcap")
    parser.add_argument("--count", type=int, default=0,
                        help="stop after this many replies; zero waits for Ctrl-C")
    args = parser.parse_args(argv)
    if args.count < 0 or args.ignore_dhcp < 0 or not 1 <= args.lease <= 0xFFFFFFFF:
        parser.error("--count and --ignore-dhcp must be non-negative; "
                     "--lease must be 1..4294967295")
    args.dns = b"".join(args.dns or [ip_bytes("192.168.77.1")])
    if len(args.dns) > 8:
        parser.error("at most two --dns values are supported")
    try:
        return 0 if serve(args, open_port(args.interface)) >= 0 else 1
    except KeyboardInterrupt:
        return 0
    except OSError as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    sys.exit(main())
