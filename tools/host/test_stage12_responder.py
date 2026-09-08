#!/usr/bin/env python3
"""Unit tests for the deterministic Stage 12 raw responder."""

import struct
import unittest

import stage10_responder as stage10
import stage11_responder as stage11
import stage12_responder as stage12


class Stage12ResponderTest(unittest.TestCase):
    def test_fixtures_are_stable(self):
        self.assertEqual(len(stage12.SMALL), 1537)
        self.assertEqual(len(stage12.LARGE), 70001)
        self.assertEqual(stage12.LARGE[:4], bytes((11, 48, 85, 122)))

    def test_endpoints(self):
        request = b"GET /RANGE.BIN HTTP/1.0\r\nRange: bytes=65536-\r\n\r\n"
        reply = stage12.endpoint("/RANGE.BIN", request)
        head, body = reply.split(b"\r\n\r\n", 1)
        self.assertIn(b"206 Partial Content", head)
        self.assertIn(b"Content-Range: bytes 65536-70000/70001", head)
        self.assertEqual(body, stage12.LARGE[65536:])
        self.assertIn(b"416 Range Not Satisfiable", stage12.endpoint(
            "/RANGE.BIN", b"GET /RANGE.BIN HTTP/1.0\r\nRange: bytes=70001-\r\n\r\n"))
        self.assertIn(b"Location: /SMALL.BIN", stage12.endpoint("/redirect", b""))
        self.assertIn(b"404 Not Found", stage12.endpoint("/missing", b""))

    def test_dns_codec(self):
        query = {"id": b"\x12\x34", "name": stage12.DNS_NAME,
                 "question": b"\x04wget\x07stage12\x04test\0\0\x01\0\x01"}
        reply = stage10.dns_reply(query, stage12.SERVICE_IP)
        self.assertEqual(reply[:2], b"\x12\x34")
        self.assertEqual(reply[-4:], stage12.SERVICE_IP)

    def test_tcp_codec(self):
        request = {"destination_port": 80, "source_port": 49152,
                   "destination": stage12.SERVICE_IP, "source": stage12.CLIENT_IP,
                   "ether_source": bytes.fromhex("02608c123456")}
        frame = stage11.build_tcp(request, 1, 2, 0x12)
        parsed = stage11.parse_tcp(frame)
        self.assertEqual(parsed["mss"], 536)
        self.assertEqual(struct.unpack("!H", frame[12:14])[0], 0x0800)

    def test_response_fills_the_advertised_window(self):
        # A responder that answers one segment per received frame is a
        # stop-and-wait pipe whatever window the client offers, which is what
        # made the receive-window work invisible in MAME. Five MSS advertised
        # has to come back as five segments off one request.
        responder = stage12.Responder("default")
        window = 5 * stage11.TCP_MSS
        # build_tcp writes a server->client frame, so hand it the mirrored
        # tuple to get a client->server one.
        mirror = {"destination_port": 49152, "source_port": stage12.HTTP_PORT,
                  "destination": stage12.CLIENT_IP, "source": stage12.SERVICE_IP,
                  "ether_source": bytes.fromhex("02608c123456")}
        client = lambda seq, ack, flags, payload=b"": stage11.build_tcp(
            mirror, seq, ack, flags, payload, window=window)
        synack = responder.handle(client(1000, 0, 0x02))
        self.assertEqual([label for label, _ in synack], ["SYNACK"])
        server_isn = stage11.parse_tcp(synack[0][1])["sequence"]
        get = b"GET /LARGE.BIN HTTP/1.0\r\nHost: wget.stage12.test\r\n\r\n"
        replies = responder.handle(client(1001, server_isn + 1, 0x18, get))
        self.assertEqual(len(replies), 5, "responder did not fill the window")
        payloads = [stage11.parse_tcp(frame)["payload"] for _, frame in replies]
        self.assertEqual(sum(len(p) for p in payloads), window)
        # Contiguous and in order, so the client accepts every one of them.
        sequences = [stage11.parse_tcp(frame)["sequence"] for _, frame in replies]
        for previous, following, payload in zip(sequences, sequences[1:], payloads):
            self.assertEqual(following, previous + len(payload))


if __name__ == "__main__":
    unittest.main()
