#!/usr/bin/env python3
"""Unit vectors for the Stage 9 UDP/TFTP raw responder and pcap checker."""

import os
import struct
import tempfile
import unittest

import stage9_responder as responder


CLIENT_MAC = bytes.fromhex("02608c123456")


def udp_request(port, payload, source_port=0x9000):
    packet = responder.ipv4_udp(responder.CLIENT_IP, responder.SERVER_IP,
                                source_port, port, payload, identifier=0x1234)
    return responder.SERVER_MAC + CLIENT_MAC + struct.pack("!H", responder.ETH_IP) + packet


def rrq(name=responder.GET_NAME, port=69):
    payload = b"\0\x01" + name.encode("ascii") + b"\0octet\0blksize\0" + b"1428\0"
    return udp_request(port, payload)


def wrq(name=responder.PUT_NAME, port=69):
    payload = b"\0\x02" + name.encode("ascii") + b"\0octet\0blksize\0" + b"1428\0"
    return udp_request(port, payload)


def response_payload(frame):
    parsed = responder.parse_udp(frame)
    return parsed["source_port"], parsed["payload"]


class Stage9ResponderTests(unittest.TestCase):
    def test_udp_echo_checksum_and_odd_payload(self):
        model = responder.Responder()
        replies = model.handle(udp_request(responder.ECHO_PORT, b"odd"))
        self.assertEqual(len(replies), 1)
        parsed = responder.parse_udp(replies[0][1])
        self.assertEqual(parsed["source_port"], responder.ECHO_PORT)
        self.assertEqual(parsed["payload"], b"odd")

    def test_request_parser_is_strict(self):
        self.assertIsNone(responder.tftp_request(b"\0\x01NAME\0netascii\0"))
        self.assertIsNone(responder.tftp_request(b"\0\x01NAME\0octet"))
        self.assertIsNone(responder.tftp_request(
            b"\0\x01NAME\0octet\0blksize\0" + b"1429\0"))
        parsed = responder.tftp_request(b"\0\x02NAME\0OCTET\0BLKSIZE\0" + b"512\0")
        self.assertEqual((parsed["opcode"], parsed["block_size"]), (2, 512))

    def test_faulted_get_loss_duplicate_reorder_and_tid(self):
        model = responder.Responder("faults")
        self.assertEqual(model.handle(rrq(port=6969)), [])
        oack = model.handle(rrq(port=6969))
        self.assertEqual(response_payload(oack[0][1])[1][:2], b"\0\x06")
        ack0 = udp_request(responder.SERVER_TID, responder.tftp_ack(0))
        first = model.handle(ack0)
        self.assertEqual(len(first), 3)
        self.assertEqual(response_payload(first[0][1])[0], responder.SERVER_TID + 1)
        self.assertEqual(response_payload(first[1][1])[1][2:4], b"\0\x01")
        ack1 = udp_request(responder.SERVER_TID, responder.tftp_ack(1))
        self.assertEqual(model.handle(ack1), [])
        retried = model.handle(ack1)
        self.assertEqual([response_payload(item[1])[1][2:4] for item in retried],
                         [b"\0\x03", b"\0\x02"])
        self.assertTrue(any(event.startswith("DROP") for event in model.events))
        self.assertTrue(any(event.startswith("RETRY") for event in model.events))

    def test_put_exact_multiple_needs_zero_final_data(self):
        with tempfile.TemporaryDirectory() as directory:
            model = responder.Responder("faults", directory)
            self.assertEqual(response_payload(model.handle(wrq())[0][1])[1][:2], b"\0\x06")
            data = responder.fixture(responder.PUT_SIZE, 0x71)
            block1 = udp_request(responder.SERVER_TID, responder.tftp_data(1, data[:1428]))
            self.assertEqual(len(model.handle(block1)), 2)
            block2 = udp_request(responder.SERVER_TID, responder.tftp_data(2, data[1428:]))
            self.assertEqual(model.handle(block2), [])
            self.assertEqual(len(model.handle(block2)), 1)
            self.assertFalse(os.path.exists(os.path.join(directory, responder.PUT_NAME)))
            final = udp_request(responder.SERVER_TID, responder.tftp_data(3, b""))
            self.assertEqual(len(model.handle(final)), 1)
            with open(os.path.join(directory, responder.PUT_NAME), "rb") as source:
                self.assertEqual(source.read(), data)

    def test_classic_pcap_validates_udp_and_tftp(self):
        model = responder.Responder()
        echo = udp_request(responder.ECHO_PORT, b"pcap")
        get_request = rrq()
        get_oack = model.handle(get_request)[0][1]
        get_frames = []
        block = 0
        while True:
            get_ack = udp_request(responder.SERVER_TID, responder.tftp_ack(block))
            get_frames.append(get_ack)
            replies = model.handle(get_ack)
            if not replies:
                break
            get_block = replies[0][1]
            get_frames.append(get_block)
            payload = response_payload(get_block)[1]
            block = struct.unpack_from("!H", payload, 2)[0]
            if len(payload) - 4 < 1428:
                break
        put_request = wrq()
        put_oack = model.handle(put_request)[0][1]
        data = responder.fixture(responder.PUT_SIZE, 0x71)
        put_frames = []
        for block in range(1, len(data) // 1428 + 2):
            chunk = data[(block - 1) * 1428:block * 1428]
            put_block = udp_request(responder.SERVER_TID, responder.tftp_data(block, chunk))
            put_frames.extend((put_block, model.handle(put_block)[0][1]))
        frames = [echo, model.handle(echo)[0][1], get_request, get_oack,
                  *get_frames, put_request, put_oack, *put_frames]
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "stage9.pcap")
            writer = responder.PcapWriter(path)
            for frame in frames:
                writer.write(frame)
            writer.close()
            self.assertEqual(responder.check_pcap(path), len(frames))

            incomplete = os.path.join(directory, "stage9-incomplete.pcap")
            writer = responder.PcapWriter(incomplete)
            for frame in frames[:-2]:
                writer.write(frame)
            writer.close()
            with self.assertRaisesRegex(ValueError, "PUT DATA block 3"):
                responder.check_pcap(incomplete)


if __name__ == "__main__":
    unittest.main()
