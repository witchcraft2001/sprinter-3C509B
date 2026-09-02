#!/usr/bin/env python3
"""Pure standard-library vectors for the Stage 10 raw responder/proxy."""

import os
import struct
import tempfile
import unittest

import stage10_responder as responder


def udp_request(destination, port, payload, source_port=0xD123):
    packet = responder.stage9.ipv4_udp(responder.CLIENT_IP, destination,
                                       source_port, port, payload, identifier=0x1234)
    return responder.SERVER_MAC + responder.CLIENT_MAC + struct.pack("!H", 0x0800) + packet


def dns_query(name="echo.stage10.test", xid=b"\x12\x34"):
    labels = b"".join(bytes((len(item),)) + item.encode("ascii") for item in name.split("."))
    return xid + b"\x01\0\0\x01\0\0\0\0\0\0" + labels + b"\0\0\x01\0\x01"


def ntp_query():
    value = bytearray(48)
    value[0] = 0x23
    value[40:48] = bytes(range(1, 9))
    return bytes(value)


def dhcp_request(message_type, ciaddr=b"\0" * 4):
    bootp = bytearray(240)
    bootp[0:4] = b"\x01\x01\x06\0"
    bootp[4:8] = b"\x12\x34\x56\x78"
    bootp[12:16] = ciaddr
    bootp[28:34] = responder.CLIENT_MAC
    bootp[236:240] = b"\x63\x82\x53\x63"
    options = bytes((53, 1, message_type, 255))
    payload = bytes(bootp) + options
    udp = bytearray(struct.pack("!HHHH", 68, 67, len(payload) + 8, 0) + payload)
    source = ciaddr
    destination = b"\xff" * 4 if ciaddr == b"\0" * 4 else responder.DHCP_IP
    struct.pack_into("!H", udp, 6, responder.stage7.udp_ipv4(source, destination, bytes(udp)))
    ip = bytearray(struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(udp), 1,
                               0x4000, 64, 17, 0, source, destination))
    struct.pack_into("!H", ip, 10, responder.stage7.checksum(bytes(ip)))
    destination_mac = b"\xff" * 6 if source == b"\0" * 4 else responder.SERVER_MAC
    return destination_mac + responder.CLIENT_MAC + b"\x08\0" + bytes(ip) + bytes(udp)


class Stage10ResponderTests(unittest.TestCase):
    def test_dhcp_acquire_renew_release(self):
        model = responder.Responder("faults", proxy_enabled=False)
        discover = dhcp_request(1)
        self.assertEqual(model.handle(discover), [])
        offer = model.handle(discover)
        self.assertEqual(responder.stage7.parse_options(offer[0][1][282:])[53], b"\x02")
        request = dhcp_request(3)
        ack = model.handle(request)
        self.assertEqual(responder.stage7.parse_options(ack[0][1][282:])[53], b"\x05")
        renew = dhcp_request(3, responder.CLIENT_IP)
        self.assertEqual(model.handle(renew), [])
        renewed = model.handle(renew)[0][1]
        self.assertEqual(renewed[58:62], b"\0" * 4)
        self.assertEqual(renewed[0:6], responder.CLIENT_MAC)
        self.assertEqual(renewed[30:34], responder.CLIENT_IP)
        self.assertEqual(responder.stage7.checksum(renewed[14:34]), 0)
        udp = renewed[34:]
        self.assertEqual(responder.stage7.udp_ipv4(
            renewed[26:30], renewed[30:34], udp), 0xFFFF)
        self.assertEqual(model.handle(dhcp_request(7, responder.CLIENT_IP)), [])
        self.assertTrue(any(event.startswith("RELEASE") for event in model.events))

    def test_dns_deterministic_nxdomain_malformed_and_stale(self):
        model = responder.Responder("faults", proxy_enabled=False)
        request = udp_request(responder.SERVICE_IP, 53, dns_query())
        replies = model.handle(request)
        self.assertEqual(len(replies), 2)
        stale = responder.stage9.parse_udp(replies[0][1])["payload"]
        good = responder.stage9.parse_udp(replies[1][1])["payload"]
        self.assertNotEqual(stale[:2], b"\x12\x34")
        self.assertEqual(good[-4:], responder.SERVICE_IP)
        nx = model.handle(udp_request(responder.SERVICE_IP, 53,
                                     dns_query("missing.stage10.test")))[0][1]
        self.assertEqual(responder.stage9.parse_udp(nx)["payload"][3] & 15, 3)
        malformed = model.handle(udp_request(
            responder.SERVICE_IP, 53, dns_query("malformed.stage10.test")))[0][1]
        body = responder.stage9.parse_udp(malformed)["payload"]
        self.assertEqual(body[-16] & 0xC0, 0xC0)

    def test_ntp_fixed_cookie_and_proxy(self):
        model = responder.Responder("faults", proxy_enabled=False)
        replies = model.handle(udp_request(responder.SERVICE_IP, 123, ntp_query()))
        self.assertEqual(len(replies), 2)
        good = responder.stage9.parse_udp(replies[1][1])["payload"]
        self.assertEqual(good[24:32], bytes(range(1, 9)))
        self.assertEqual(struct.unpack_from("!I", good, 40)[0],
                         responder.FIXED_UNIX_SECONDS + 2208988800)

        calls = []
        def exchange(destination, port, payload):
            calls.append((destination, port, payload))
            return b"proxied"
        proxy = responder.Responder(proxy_exchange=exchange)
        public = bytes((1, 1, 1, 1))
        result = proxy.handle(udp_request(public, 53, dns_query()))
        self.assertEqual(calls[0][0:2], (public, 53))
        self.assertEqual(responder.stage9.parse_udp(result[0][1])["payload"], b"proxied")
        self.assertTrue(any(event.startswith("PROXY ok") for event in proxy.events))

    def test_echo_tftp_and_classic_pcap_protocol_inventory(self):
        model = responder.Responder(proxy_enabled=False)
        echo = udp_request(responder.SERVICE_IP, responder.stage9.ECHO_PORT, b"exact")
        echo_reply = model.handle(echo)[0][1]
        rrq_payload = b"\0\x01S9GET.BIN\0octet\0blksize\0" + b"1428\0"
        rrq = udp_request(responder.SERVICE_IP, 6969, rrq_payload, 0x9000)
        tftp_reply = model.handle(rrq)[0][1]
        dns = udp_request(responder.SERVICE_IP, 53, dns_query())
        dns_answer = model.handle(dns)[0][1]
        ntp = udp_request(responder.SERVICE_IP, 123, ntp_query())
        ntp_answer = model.handle(ntp)[0][1]
        frames = [dhcp_request(1), dhcp_request(3), dhcp_request(7, responder.CLIENT_IP),
                  dns, dns_answer, ntp, ntp_answer, echo, echo_reply, rrq, tftp_reply]
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "stage10.pcap")
            writer = responder.stage7.PcapWriter(path)
            for frame in frames:
                writer.write(frame)
            writer.close()
            counts = responder.check_pcap(path)
            self.assertEqual(counts["release"], 1)
            self.assertGreaterEqual(counts["dns"], 2)


if __name__ == "__main__":
    unittest.main()
