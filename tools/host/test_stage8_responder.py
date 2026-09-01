#!/usr/bin/env python3
"""Unit vectors for the Stage 8 raw responder and pcap writer."""

import os
import struct
import tempfile
import unittest

import stage8_responder as responder


def request(target=responder.LOCAL_IP, size=32):
    client_mac = bytes.fromhex("02608c123456")
    destination_mac = responder.LOCAL_MAC if target == responder.LOCAL_IP else responder.GATEWAY_MAC
    body = bytearray(b"\x08\0\0\0\x50\x9b\0\x07" + bytes(i & 255 for i in range(size)))
    struct.pack_into("!H", body, 2, responder.checksum(bytes(body)))
    packet = responder.ipv4_packet(responder.CLIENT_IP, target, bytes(body), ttl=255, identifier=0x1234)
    return destination_mac + client_mac + struct.pack("!H", responder.ETH_IP) + packet


class FakePort:
    def __init__(self, frames):
        self.frames = list(frames)
        self.sent = []
        self.closed = False

    def receive(self):
        if not self.frames:
            raise KeyboardInterrupt
        return self.frames.pop(0)

    def send(self, frame):
        self.sent.append(frame)

    def close(self):
        self.closed = True


class Stage8ResponderTests(unittest.TestCase):
    def test_echo_and_checksums(self):
        parsed = responder.parse_echo_request(request(size=1))
        self.assertIsNotNone(parsed)
        reply = responder.echo_reply(parsed, responder.LOCAL_MAC)
        self.assertGreaterEqual(len(reply), 60)
        ip = reply[14:]
        total = struct.unpack_from("!H", ip, 2)[0]
        self.assertEqual(responder.checksum(ip[:20]), 0)
        self.assertEqual(responder.checksum(ip[20:total]), 0)
        self.assertEqual(ip[20], 0)

    def test_reserved_flag_and_oversize_are_rejected(self):
        frame = bytearray(request(size=1))
        frame[20] = 0xC0
        frame[24:26] = b"\0\0"
        struct.pack_into("!H", frame, 24, responder.checksum(bytes(frame[14:34])))
        self.assertIsNone(responder.parse_echo_request(bytes(frame)))

        frame = bytearray(request(size=1))
        struct.pack_into("!H", frame, 16, 1501)
        frame.extend(b"\0" * (14 + 1501 - len(frame)))
        frame[24:26] = b"\0\0"
        struct.pack_into("!H", frame, 24, responder.checksum(bytes(frame[14:34])))
        self.assertIsNone(responder.parse_echo_request(bytes(frame)))

    def test_routed_unreachable_quote(self):
        parsed = responder.parse_echo_request(request(responder.EXTERNAL_IP))
        frame = responder.unreachable(parsed, responder.GATEWAY_MAC)
        ip = frame[14:]
        self.assertEqual(ip[12:16], responder.GATEWAY_IP)
        self.assertEqual(ip[20], 3)
        self.assertEqual(ip[28:56], parsed["ip"][:28])
        self.assertEqual(responder.checksum(ip[20:]), 0)

    def test_noise_then_valid(self):
        parsed = responder.parse_echo_request(request())
        frames = responder.replies_for_echo(parsed, "noise")
        self.assertEqual(len(frames), 5)
        self.assertNotEqual(responder.checksum(frames[1][14:34]), 0)
        self.assertEqual(responder.checksum(frames[-1][14:34]), 0)

    def test_classic_pcap_exact_lengths(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "stage8.pcap")
            writer = responder.PcapWriter(path)
            writer.write(request(size=0))
            writer.close()
            self.assertEqual(responder.check_pcap(path), 1)


if __name__ == "__main__":
    unittest.main()
