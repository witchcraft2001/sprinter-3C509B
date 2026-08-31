#!/usr/bin/env python3
"""Raw Ethernet sender and strict classic-pcap verifier for Stage 6."""

import argparse
import fcntl
import os
import platform
import socket
import struct
import sys
import time


def mac_bytes(text):
    parts = text.split(":")
    if len(parts) != 6:
        raise argparse.ArgumentTypeError("MAC must contain six hexadecimal bytes")
    try:
        value = bytes(int(part, 16) for part in parts)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("invalid MAC") from exc
    if any(len(part) != 2 for part in parts):
        raise argparse.ArgumentTypeError("MAC bytes must use two digits")
    return value


def pattern_byte(pattern, index, sequence):
    if pattern == "INC":
        return (index + sequence) & 0xFF
    return {"00": 0x00, "FF": 0xFF, "55": 0x55, "AA": 0xAA}[pattern]


def build_frame(destination, source, ethertype, input_length, pattern, sequence=0):
    if not 14 <= input_length <= 1514:
        raise ValueError("input length must be 14..1514")
    frame = bytearray(destination + source + struct.pack("!H", ethertype))
    while len(frame) < input_length:
        frame.append(pattern_byte(pattern, len(frame) - 14, sequence))
    frame.extend(b"\0" * (max(input_length, 60) - len(frame)))
    return bytes(frame)


def send_linux(interface, frames, interval=0.0):
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                       socket.htons(0x0003)) as raw:  # ETH_P_ALL
        raw.bind((interface, 0))
        for index, frame in enumerate(frames):
            raw.send(frame)
            if interval and index + 1 != len(frames):
                time.sleep(interval)


def open_bpf(interface):
    descriptor = None
    for number in range(256):
        try:
            descriptor = os.open(f"/dev/bpf{number}", os.O_RDWR)
            break
        except OSError:
            continue
    if descriptor is None:
        raise OSError("no writable /dev/bpf device")
    try:
        ifreq = struct.pack("16s16x", interface.encode("ascii"))
        fcntl.ioctl(descriptor, 0x8020426C, ifreq)  # BIOCSETIF
        fcntl.ioctl(descriptor, 0x80044275, struct.pack("I", 1))  # BIOCSHDRCMPLT
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def send_macos(interface, frames, interval=0.0):
    descriptor = open_bpf(interface)
    try:
        for index, frame in enumerate(frames):
            written = os.write(descriptor, frame)
            if written != len(frame):
                raise OSError(f"short BPF write: {written}/{len(frame)}")
            if interval and index + 1 != len(frames):
                time.sleep(interval)
    finally:
        os.close(descriptor)


def send_frames(interface, frames, interval):
    system = platform.system()
    if system == "Linux":
        send_linux(interface, frames, interval)
    elif system == "Darwin":
        send_macos(interface, frames, interval)
    else:
        raise OSError(f"raw Ethernet is unsupported on {system}")


def read_classic_pcap(path):
    with open(path, "rb") as capture:
        data = capture.read()
    if len(data) < 24:
        raise ValueError("pcap is shorter than the global header")
    magic = data[:4]
    formats = {
        b"\xd4\xc3\xb2\xa1": "<", b"\xa1\xb2\xc3\xd4": ">",
        b"\x4d\x3c\xb2\xa1": "<", b"\xa1\xb2\x3c\x4d": ">",
    }
    if magic not in formats:
        raise ValueError("only classic pcap (micro/nanosecond) is accepted")
    endian = formats[magic]
    _, _, _, _, _, linktype = struct.unpack_from(endian + "HHIIII", data, 4)
    if linktype != 1:
        raise ValueError(f"pcap linktype {linktype} is not Ethernet")
    packets = []
    offset = 24
    while offset < len(data):
        if offset + 16 > len(data):
            raise ValueError("truncated pcap packet header")
        _, _, captured, wire = struct.unpack_from(endian + "IIII", data, offset)
        offset += 16
        if captured > wire or offset + captured > len(data):
            raise ValueError("invalid/truncated pcap packet")
        packets.append((data[offset:offset + captured], captured, wire))
        offset += captured
    return packets


def verify_pcap(path, expected):
    packets = read_classic_pcap(path)
    matching = []
    for packet, captured, wire in packets:
        if len(packet) >= 14 and packet[:14] == expected[0][:14]:
            matching.append((packet, captured, wire))
    if len(matching) != len(expected):
        raise ValueError(f"expected {len(expected)} matching packets, got {len(matching)}")
    for index, ((packet, captured, wire), wanted) in enumerate(zip(matching, expected)):
        if captured != len(wanted) or wire != len(wanted):
            raise ValueError(
                f"packet {index}: caplen/wire {captured}/{wire}, expected {len(wanted)} without FCS"
            )
        if packet != wanted:
            mismatch = next((i for i, pair in enumerate(zip(packet, wanted)) if pair[0] != pair[1]), None)
            raise ValueError(f"packet {index}: byte mismatch at {mismatch}")
    return len(matching)


def common_frame_arguments(parser):
    parser.add_argument("--destination", required=True, type=mac_bytes)
    parser.add_argument("--source", required=True, type=mac_bytes)
    parser.add_argument("--ethertype", default="88B5")
    parser.add_argument("--length", type=int, default=60, dest="input_length")
    parser.add_argument("--pattern", choices=("00", "FF", "55", "AA", "INC"), default="INC")
    parser.add_argument("--count", type=int, default=1)


def parse_ethertype(text):
    value = int(text.removeprefix("#").removeprefix("0x"), 16)
    if not 0x0600 <= value <= 0xFFFF:
        raise ValueError("EtherType must be #0600..#FFFF")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sender = sub.add_parser("send")
    sender.add_argument("--interface", required=True)
    sender.add_argument("--interval", type=float, default=0.0)
    common_frame_arguments(sender)
    verifier = sub.add_parser("verify-pcap")
    verifier.add_argument("pcap")
    common_frame_arguments(verifier)
    args = parser.parse_args(argv)
    if not 1 <= args.count <= 100:
        parser.error("--count must be 1..100")
    if args.command == "send" and args.interval < 0:
        parser.error("--interval must be non-negative")
    try:
        ethertype = parse_ethertype(args.ethertype)
        frames = [build_frame(args.destination, args.source, ethertype,
                              args.input_length, args.pattern, sequence)
                  for sequence in range(args.count)]
        if args.command == "send":
            send_frames(args.interface, frames, args.interval)
            print(f"sent {len(frames)} Ethernet frame(s) through {args.interface}")
        else:
            count = verify_pcap(args.pcap, frames)
            print(f"pcap verified: {count} exact Ethernet frame(s), no FCS")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"error: {exc}\n")


if __name__ == "__main__":
    main()
