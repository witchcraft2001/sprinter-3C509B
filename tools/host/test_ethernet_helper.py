#!/usr/bin/env python3
"""Standard-library unit checks for ethernet_helper.py."""

import os
import struct
import tempfile

import ethernet_helper as helper


def write_pcap(path, frames, wire_extra=0):
    with open(path, "wb") as output:
        output.write(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for index, frame in enumerate(frames):
            output.write(struct.pack("<IIII", index, 0, len(frame), len(frame) + wire_extra))
            output.write(frame)


def expect_rejected(path, expected):
    try:
        helper.verify_pcap(path, expected)
    except ValueError:
        return
    raise AssertionError("invalid capture was accepted")


def main():
    destination = helper.mac_bytes("02:00:00:00:00:01")
    source = helper.mac_bytes("02:60:8C:12:34:56")
    for length in (14, 42, 59, 60, 61, 62, 63, 1514):
        for pattern in ("00", "FF", "55", "AA", "INC"):
            frames = [helper.build_frame(destination, source, 0x88B5, length, pattern, i)
                      for i in range(10)]
            assert all(len(frame) == max(length, 60) for frame in frames)
            with tempfile.NamedTemporaryFile(delete=False) as capture:
                capture_path = capture.name
            try:
                write_pcap(capture_path, frames)
                assert helper.verify_pcap(capture_path, frames) == 10
                damaged = bytearray(frames[0]); damaged[-1] ^= 1
                expect_rejected(capture_path, [bytes(damaged)] + frames[1:])
            finally:
                os.unlink(capture_path)

    frame = helper.build_frame(destination, source, 0x88B5, 60, "INC")
    with tempfile.NamedTemporaryFile(delete=False) as capture:
        capture_path = capture.name
    try:
        write_pcap(capture_path, [frame + b"\0\0\0\0"])
        expect_rejected(capture_path, [frame])
        write_pcap(capture_path, [frame], wire_extra=4)
        expect_rejected(capture_path, [frame])
    finally:
        os.unlink(capture_path)
    print("Ethernet helper: classic-pcap lengths, patterns, padding, burst order and no-FCS checks passed")


if __name__ == "__main__":
    main()
