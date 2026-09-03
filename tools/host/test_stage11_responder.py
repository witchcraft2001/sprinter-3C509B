#!/usr/bin/env python3
"""Host tests for the deterministic Stage 11 TCP responder."""

import os
import struct
import tempfile
import unittest

import stage7_responder as stage7
import stage11_responder as stage11


def client_frame(port, sequence, acknowledgement, flags, payload=b"", window=536):
    options = b"\x02\x04\x02\x18" if flags & 2 else b""
    header_length = 20 + len(options)
    tcp = bytearray(struct.pack("!HHIIBBHHH", port, stage11.TCP_PORT,
                                sequence, acknowledgement,
                                (header_length // 4) << 4, flags,
                                window, 0, 0) + options + payload)
    pseudo = (stage11.CLIENT_IP + stage11.SERVICE_IP + b"\0\x06" +
              struct.pack("!H", len(tcp)) + tcp)
    struct.pack_into("!H", tcp, 16, stage7.checksum(pseudo))
    total = 20 + len(tcp)
    ip_header = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, total,
                                      0x1234, 0x4000, 64, 6, 0,
                                      stage11.CLIENT_IP, stage11.SERVICE_IP))
    struct.pack_into("!H", ip_header, 10, stage7.checksum(ip_header))
    frame = bytearray(stage11.SERVER_MAC + stage11.CLIENT_MAC +
                      b"\x08\x00" + ip_header + tcp)
    frame.extend(b"\0" * max(0, 60 - len(frame)))
    return bytes(frame)


class Stage11ResponderTests(unittest.TestCase):
    def handshake(self, responder, port, isn):
        request = client_frame(port, isn, 0, 2)
        replies = responder.handle(request)
        self.assertEqual(len(replies), 1)
        synack = stage11.parse_tcp(replies[0][1])
        self.assertEqual(synack["flags"], 0x12)
        self.assertEqual(synack["mss"], stage11.TCP_MSS)
        responder.handle(client_frame(port, isn + 1, synack["sequence"] + 1, 0x10))
        return request, synack

    def test_two_channels_echo_and_close(self):
        responder = stage11.Responder()
        sessions = [self.handshake(responder, 0xC011, 0x10203040),
                    self.handshake(responder, 0xC122, 0x20304050)]
        for index, (_syn, synack) in enumerate(sessions):
            port, sequence = (0xC011, 0x10203041) if index == 0 else (0xC122, 0x20304051)
            payload = bytes((value ^ (0x31 if index == 0 else 0xA7)) & 255
                            for value in range(stage11.TCP_MSS))
            replies = responder.handle(client_frame(
                port, sequence, synack["sequence"] + 1, 0x18, payload))
            echo = stage11.parse_tcp(replies[-1][1])
            self.assertEqual(echo["payload"], payload)
            self.assertEqual(echo["acknowledgement"], sequence + len(payload))
            responder.handle(client_frame(port, sequence + len(payload),
                                          echo["sequence"] + len(payload), 0x10))
            fin = responder.handle(client_frame(port, sequence + len(payload),
                                                echo["sequence"] + len(payload), 0x11))
            self.assertTrue(stage11.parse_tcp(fin[0][1])["flags"] & 1)
        self.assertEqual(len(responder.connections), 2)

    def test_fault_profiles(self):
        faults = stage11.Responder("faults")
        self.assertEqual(faults.handle(client_frame(0xC001, 1, 0, 2)), [])
        replies = faults.handle(client_frame(0xC001, 1, 0, 2))
        self.assertEqual(len(replies), 1)
        synack = stage11.parse_tcp(replies[0][1])
        repeated = stage11.parse_tcp(
            faults.handle(client_frame(0xC001, 1, 0, 2))[0][1])
        self.assertEqual(repeated["sequence"], synack["sequence"])
        faults.handle(client_frame(0xC001, 2, synack["sequence"] + 1, 0x10))
        self.assertEqual(faults.handle(client_frame(0xC001, 2,
                                                   synack["sequence"] + 1,
                                                   0x18, b"abc")), [])
        replies = faults.handle(client_frame(0xC001, 2,
                                             synack["sequence"] + 1,
                                             0x18, b"abc"))
        self.assertEqual([label for label, _frame in replies],
                         ["OUT-OF-ORDER", "DATA", "DUPLICATE"])

        zero = stage11.Responder("zero")
        _request, synack = self.handshake(zero, 0xC002, 20)
        self.assertEqual(synack["window"], 0)
        for probe in range(1, 4):
            reply = zero.handle(client_frame(0xC002, 20,
                                             synack["sequence"] + 1, 0x10,
                                             b"x"))[0][1]
            self.assertEqual(stage11.parse_tcp(reply)["window"], 4096 if probe == 3 else 0)

        reset = stage11.Responder("reset")
        _request, synack = self.handshake(reset, 0xC003, 30)
        reply = reset.handle(client_frame(0xC003, 31, synack["sequence"] + 1,
                                          0x18, b"x"))[0][1]
        self.assertTrue(stage11.parse_tcp(reply)["flags"] & 4)
        _request, synack = self.handshake(reset, 0xC004, 40)
        replies = reset.handle(client_frame(0xC004, 41,
                                            synack["sequence"] + 1, 0x18, b"x"))
        self.assertEqual([label for label, _frame in replies], ["DATA"])

    def test_parser_and_pcap_gate(self):
        responder = stage11.Responder()
        syn0, reply0 = self.handshake(responder, 0xC010, 100)
        syn1, reply1 = self.handshake(responder, 0xC110, 200)
        data = client_frame(0xC010, 101, reply0["sequence"] + 1, 0x18, b"payload")
        echo = responder.handle(data)[0][1]
        data1 = client_frame(0xC110, 201, reply1["sequence"] + 1, 0x18, b"x")
        echo1 = responder.handle(data1)[0][1]
        fin = client_frame(0xC010, 108, reply0["sequence"] + 8, 0x11)
        fin_reply = responder.handle(fin)[0][1]
        fin1 = client_frame(0xC110, 202, reply1["sequence"] + 2, 0x11)
        fin_reply1 = responder.handle(fin1)[0][1]
        damaged = bytearray(data); damaged[40] ^= 1
        self.assertIsNone(stage11.parse_tcp(bytes(damaged)))
        self.assertIsNone(stage11.parse_tcp(client_frame(0, 1, 0, 2)))
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "stage11.pcap")
            writer = stage7.PcapWriter(path)
            for frame in (syn0, stage11.build_tcp(stage11.parse_tcp(syn0),
                          reply0["sequence"], 101, 0x12),
                          syn1, data, echo, data1, echo1, fin, fin_reply,
                          fin1, fin_reply1):
                writer.write(frame)
            writer.close()
            frames = stage11.check_pcap(path)
            self.assertGreaterEqual(len(frames), 6)


if __name__ == "__main__":
    unittest.main()
