#!/usr/bin/env python3
"""Unit tests for the deterministic Stage 13 raw FTP responder."""

import struct
import unittest

import stage7_responder as stage7
import stage9_responder as stage9
import stage11_responder as stage11
import stage13_responder as stage13


CLIENT_PORT = 51000
CLIENT_MAC = bytes.fromhex("02608c123456")


def arp_request_frame(target_ip):
    arp = (b"\x00\x01\x08\x00\x06\x04\x00\x01" + CLIENT_MAC + stage13.CLIENT_IP +
           b"\0" * 6 + target_ip)
    return b"\xff" * 6 + CLIENT_MAC + struct.pack("!H", stage7.ETH_ARP) + arp


def dns_query_frame(name, xid=b"\x12\x34"):
    labels = b"".join(bytes((len(item),)) + item.encode("ascii") for item in name.split("."))
    payload = xid + b"\x01\0\0\x01\0\0\0\0\0\0" + labels + b"\0\0\x01\0\x01"
    packet = stage9.ipv4_udp(stage13.CLIENT_IP, stage13.SERVICE_IP, 0xD123, 53,
                              payload, identifier=0x1234)
    return stage13.SERVER_MAC + CLIENT_MAC + struct.pack("!H", 0x0800) + packet


def mirror(destination_port):
    # build_tcp always emits server->client frames, so a client-facing test
    # frame needs a manually swapped source/destination dict (same trick as
    # test_stage12_responder.py's test_response_fills_the_advertised_window).
    return {"destination_port": CLIENT_PORT, "source_port": destination_port,
            "destination": stage13.CLIENT_IP, "source": stage13.SERVICE_IP,
            "ether_source": bytes.fromhex("02608c123456")}


def client_frame(destination_port, seq, ack, flags, payload=b"", window=4096):
    return stage11.build_tcp(mirror(destination_port), seq, ack, flags, payload,
                              window=window)


def payloads_of(replies):
    return [stage11.parse_tcp(frame)["payload"] for _, frame in replies]


class Session:
    """Drives one control-channel dialog, tracking sequence numbers so each
    test only has to name the FTP command text, not the TCP bookkeeping."""

    def __init__(self, responder, client_seq=1000, window=4096):
        self.responder = responder
        self.window = window
        synack = responder.handle(client_frame(stage13.CONTROL_PORT, client_seq, 0, 0x02,
                                                window=window))
        assert [label for label, _ in synack] == ["SYNACK"]
        server_isn = stage11.parse_tcp(synack[0][1])["sequence"]
        self.client_seq = client_seq + 1
        self.banner = responder.handle(client_frame(
            stage13.CONTROL_PORT, self.client_seq, server_isn + 1, 0x10, window=window))
        assert len(self.banner) == 1, "banner must be pushed on the handshake ACK alone"
        self.server_next = self._advance(self.banner)

    @staticmethod
    def _advance(frames):
        server_next = 0
        for _, frame in frames:
            parsed = stage11.parse_tcp(frame)
            server_next = max(server_next, parsed["sequence"] + max(len(parsed["payload"]), 1))
        return server_next

    def send(self, text):
        payload = text.encode("ascii")
        replies = self.responder.handle(client_frame(
            stage13.CONTROL_PORT, self.client_seq, self.server_next, 0x18, payload,
            window=self.window))
        self.client_seq += len(payload)
        if replies:
            self.server_next = self._advance(replies)
        return replies


class Stage13ResponderTest(unittest.TestCase):
    def test_fixtures_are_stable(self):
        self.assertEqual(len(stage13.SMALL), 211)
        self.assertEqual(len(stage13.LARGE), 3000)

    def test_arp_for_the_service_ip_gets_a_reply(self):
        # Regression test: the client can't open the control channel at all
        # without resolving SERVICE_IP's MAC first, and this responder went a
        # whole MAME acceptance run silently never answering that ARP request
        # -- test_stage12_responder.py never had this gap because
        # stage12_responder.py kept the ARP branch stage13_responder.py's
        # handle() had dropped when it was ported from that same shape.
        responder = stage13.Responder()
        replies = responder.handle(arp_request_frame(stage13.SERVICE_IP))
        self.assertEqual([label for label, _ in replies], ["ARP"])
        # build_arp_reply produced a real ARP reply (opcode 2): decode it by
        # hand since parse_arp_request only recognises opcode 1 (requests).
        arp = replies[0][1][14:42]
        self.assertEqual(arp[:8], b"\x00\x01\x08\x00\x06\x04\x00\x02")
        self.assertEqual(arp[8:14], stage13.SERVER_MAC)
        self.assertEqual(arp[14:18], stage13.SERVICE_IP)
        self.assertEqual(arp[18:24], CLIENT_MAC)
        self.assertEqual(arp[24:28], stage13.CLIENT_IP)

    def test_arp_for_another_ip_is_ignored(self):
        responder = stage13.Responder()
        other_ip = bytes((192, 168, 7, 1))
        self.assertEqual(responder.handle(arp_request_frame(other_ip)), [])

    def test_dns_resolves_the_documented_hostname(self):
        # Regression test: docs/STAGE13_TESTING_RU.md has the operator run
        # `FTP ftp.stage13.test ...` and `NSLOOKUP ftp.stage13.test`, but this
        # responder never answered port 53 at all -- every such run spent the
        # DNS resolver's full 2-attempt/5s-each timeout (~10-30s including
        # DNS1/DNS2 fallback) and then failed with "[E] resolve fail." /
        # EL3_ERR_RX_TIMEOUT (code 14), even after ARP resolution was fixed.
        responder = stage13.Responder()
        replies = responder.handle(dns_query_frame(stage13.DNS_NAME))
        self.assertEqual([label for label, _ in replies], ["DNS"])
        udp = stage9.parse_udp(replies[0][1])
        self.assertEqual(udp["payload"][:2], b"\x12\x34")
        self.assertEqual(udp["payload"][-4:], stage13.SERVICE_IP)

    def test_dns_for_another_name_is_ignored(self):
        responder = stage13.Responder()
        self.assertEqual(responder.handle(dns_query_frame("unknown.stage13.test")), [])

    def test_banner_pushed_on_syn_ack_without_a_request(self):
        responder = stage13.Responder()
        session = Session(responder)
        self.assertEqual(len(session.banner), 1)
        parsed = stage11.parse_tcp(session.banner[0][1])
        self.assertEqual(parsed["payload"], stage13.BANNER)

    def open_data_channel(self, responder, port, client_seq, window=4096):
        synack = responder.handle(client_frame(port, client_seq, 0, 0x02, window=window))
        self.assertEqual([label for label, _ in synack], ["SYNACK"])
        isn = stage11.parse_tcp(synack[0][1])["sequence"]
        established = responder.handle(client_frame(port, client_seq + 1, isn + 1, 0x10,
                                                      window=window))
        self.assertEqual(established, [],
                          "an established data channel is idle until a verb arrives")
        return isn + 1

    def test_http_serves_large_fixture_for_dlspeed(self):
        # DLSPEED is bundled into the same Stage 13 image/acceptance run (see
        # specs.md's joint speed comparison), so it has to work against this
        # same responder process without a second one just for HTTP.
        responder = stage13.Responder()
        window = 5 * stage11.TCP_MSS
        server_next = self.open_data_channel(responder, stage13.HTTP_PORT,
                                              client_seq=10000, window=window)
        request = b"GET / HTTP/1.0\r\nHost: ftp.stage13.test\r\n\r\n"
        replies = responder.handle(client_frame(stage13.HTTP_PORT, 10001, server_next,
                                                 0x18, request, window=window))
        labels = [label for label, _ in replies]
        self.assertIn("HTTP", labels)
        # One handle() call only fills the advertised window (the window-
        # filling behavior test_response_fills_the_advertised_window checks
        # for the FTP data channel applies here too); a real client ACKs
        # progressively and gets the rest across later frames.
        received = b"".join(stage11.parse_tcp(frame)["payload"] for _, frame in replies)
        self.assertEqual(len(received), window)
        head, partial_body = received.split(b"\r\n\r\n", 1)
        self.assertIn(b"200 OK", head)
        self.assertIn(f"Content-Length: {len(stage13.HTTP_LARGE)}".encode(), head)
        self.assertIn(b"Connection: keep-alive", head)
        self.assertFalse(any(stage11.parse_tcp(frame)["flags"] & 1
                             for _, frame in replies),
                         "HTTP responder must not delimit the benchmark with FIN")
        self.assertEqual(partial_body, stage13.HTTP_LARGE[:len(partial_body)])

    def test_http_fixture_is_its_own_large_body_not_ftps(self):
        # Regression guard: DLSPEED's fixture must stay decoupled from FTP's
        # 3000-byte LARGE (see the comment above HTTP_LARGE) and big enough
        # that a transfer can't complete inside one RTC second and get
        # rejected by DLSPEED's own "sample too short" check.
        self.assertNotEqual(len(stage13.HTTP_LARGE), len(stage13.LARGE))
        self.assertEqual(len(stage13.HTTP_LARGE), 4 * 1024 * 1024)

    def test_control_lines_are_logged_verbatim(self):
        # Diagnostic aid: a mismatch between what ftp.asm typed on screen and
        # what the responder actually received (a stray byte, wrong case, a
        # truncation) has to show up in the event log, or a live failure like
        # "550 Could not get file size." for a fixture that plainly exists
        # can't be told apart from a real missing-fixture case after the
        # fact.
        responder = stage13.Responder()
        session = Session(responder)
        session.send("USER anonymous\r\n")
        self.assertIn("CMD 'USER anonymous'", responder.events)

    def test_user_pass_type_pasv_retr_happy_path(self):
        responder = stage13.Responder()
        session = Session(responder)

        self.assertEqual(payloads_of(session.send("USER anonymous\r\n")),
                          [b"331 User anonymous OK, need password.\r\n"])
        self.assertEqual(payloads_of(session.send("PASS anonymous@\r\n")),
                          [b"230 Login successful.\r\n"])
        self.assertEqual(payloads_of(session.send("TYPE I\r\n")),
                          [b"200 Type set to I.\r\n"])
        pasv_payloads = payloads_of(session.send("PASV\r\n"))
        self.assertEqual(len(pasv_payloads), 1)
        self.assertTrue(pasv_payloads[0].startswith(b"227 "))
        self.assertEqual(responder.data_port, stage13.FIRST_DATA_PORT)

        # ftp.asm opens the data channel (and completes its handshake)
        # before ever sending RETR/STOR/LIST.
        self.open_data_channel(responder, responder.data_port, client_seq=5000)

        retr_replies = session.send("RETR SMALL.BIN\r\n")
        labels = [label for label, _ in retr_replies]
        # Pushing the data-channel fixture happens out of band (triggered by
        # the RETR command itself, since the data channel has nothing of its
        # own to trigger a reply on): "150" and "226" both end up queued on
        # the control connection before either is drained, so a fixture this
        # small has them coalesced into one segment together, and the RETR
        # command's own segment gets a bare ACK since nothing was left in the
        # control queue by the time handle() reaches its own reply.
        self.assertEqual(labels, ["ACK", "REPLY", "DATA"])
        reply_payload = stage11.parse_tcp(retr_replies[1][1])["payload"]
        self.assertEqual(reply_payload,
                          b"150 Opening data connection.\r\n226 Transfer complete.\r\n")
        self.assertEqual(stage11.parse_tcp(retr_replies[2][1])["payload"], stage13.SMALL)
        self.assertEqual(stage11.parse_tcp(retr_replies[2][1])["flags"] & 0x01, 0x01,
                          "the last (only) data segment must carry FIN")
        self.assertEqual(responder.requests, [
            "USER anonymous", "PASS anonymous@", "TYPE I", "PASV", "RETR SMALL.BIN",
        ])

    def test_rest_actually_skips_the_resumed_prefix(self):
        # Regression test: REST used to be accepted ("350 Restarting at N")
        # and then completely ignored -- RETR always pushed the fixture from
        # byte 0. A live `FTP ... LARGE.BIN -r` run against a fully-downloaded
        # local file re-received the whole 3000-byte body and appended it,
        # corrupting the file the resume was supposed to leave untouched.
        responder = stage13.Responder()
        session = Session(responder)
        session.send("USER anonymous\r\n")
        session.send("PASS anonymous@\r\n")
        session.send("TYPE I\r\n")
        session.send("PASV\r\n")
        self.open_data_channel(responder, responder.data_port, client_seq=7000)

        session.send("REST 2000\r\n")
        retr_replies = session.send("RETR LARGE.BIN\r\n")
        data_frames = [frame for label, frame in retr_replies if label == "DATA"]
        received = b"".join(stage11.parse_tcp(frame)["payload"] for frame in data_frames)
        self.assertEqual(received, stage13.LARGE[2000:])

    def test_rest_at_eof_sends_fin_and_226(self):
        # An empty tail still has protocol completion: without the FIN-only
        # data segment the client waits its whole data timeout after a valid
        # REST == SIZE request (the failure seen in the live MAME run).
        responder = stage13.Responder()
        session = Session(responder)
        session.send("USER anonymous\r\n")
        session.send("PASS anonymous@\r\n")
        session.send("TYPE I\r\n")
        session.send("PASV\r\n")
        self.open_data_channel(responder, responder.data_port, client_seq=7200)

        session.send(f"REST {len(stage13.LARGE)}\r\n")
        replies = session.send("RETR LARGE.BIN\r\n")
        empty_fin = [stage11.parse_tcp(frame) for label, frame in replies
                     if label == "DATA"]
        self.assertEqual(len(empty_fin), 1)
        self.assertEqual(empty_fin[0]["payload"], b"")
        self.assertTrue(empty_fin[0]["flags"] & 0x01)
        queued_control = bytes(
            responder.connections[responder.control_key].send_queue)
        self.assertTrue(any(b"226 Transfer complete.\r\n" in
                            stage11.parse_tcp(frame)["payload"]
                            for _, frame in replies) or
                        b"226 Transfer complete.\r\n" in queued_control)

    def test_rest_does_not_carry_over_to_the_next_transfer(self):
        # A RETR with no REST of its own must start at 0, even right after a
        # resumed one -- REST applies to exactly the transfer command that
        # follows it, never further.
        responder = stage13.Responder()
        session = Session(responder)
        session.send("USER anonymous\r\n")
        session.send("PASS anonymous@\r\n")
        session.send("TYPE I\r\n")
        session.send("PASV\r\n")
        self.open_data_channel(responder, responder.data_port, client_seq=7500)
        session.send("REST 2000\r\n")
        session.send("RETR LARGE.BIN\r\n")

        session.send("PASV\r\n")
        self.open_data_channel(responder, responder.data_port, client_seq=8500)
        retr_replies = session.send("RETR SMALL.BIN\r\n")
        data_frames = [frame for label, frame in retr_replies if label == "DATA"]
        received = b"".join(stage11.parse_tcp(frame)["payload"] for frame in data_frames)
        self.assertEqual(received, stage13.SMALL)

    def test_stor_capture(self):
        responder = stage13.Responder()
        session = Session(responder)
        session.send("USER anonymous\r\n")
        session.send("PASS anonymous@\r\n")
        session.send("TYPE I\r\n")
        session.send("PASV\r\n")
        data_next = self.open_data_channel(responder, responder.data_port, client_seq=6000)

        stor_replies = session.send("STOR UPLOAD.BIN\r\n")
        self.assertEqual(payloads_of(stor_replies), [b"150 Opening data connection.\r\n"])

        payload = b"uploaded payload bytes, byte for byte"
        data_client_seq = 6001
        responder.handle(client_frame(responder.data_port, data_client_seq, data_next,
                                       0x18, payload))
        data_client_seq += len(payload)
        fin_replies = responder.handle(client_frame(
            responder.data_port, data_client_seq, data_next, 0x11))
        self.assertEqual([label for label, _ in fin_replies][0], "FIN-ACK")
        self.assertEqual(responder.uploads.get("UPLOAD.BIN"), payload)
        # The upload's completion is what triggers "226", on the control
        # channel, out of band from the data channel's own FIN-ACK.
        self.assertTrue(any(
            stage11.parse_tcp(frame)["payload"] == b"226 Transfer complete.\r\n"
            for _, frame in fin_replies))

    def test_response_fills_the_advertised_window(self):
        # A responder that answers one segment per received frame is a
        # stop-and-wait pipe whatever window the client offers -- five MSS
        # advertised has to come back as (at least) five segments off one
        # RETR, exactly like Stage 12's own equivalent check.
        window = 5 * stage11.TCP_MSS
        responder = stage13.Responder()
        session = Session(responder, client_seq=2000, window=window)
        session.send("USER anonymous\r\n")
        session.send("PASS anonymous@\r\n")
        session.send("TYPE I\r\n")
        session.send("PASV\r\n")
        self.open_data_channel(responder, responder.data_port, client_seq=9000, window=window)

        retr_replies = session.send("RETR LARGE.BIN\r\n")
        data_frames = [frame for label, frame in retr_replies if label == "DATA"]
        self.assertGreaterEqual(len(data_frames), 5, "responder did not fill the window")
        payloads = [stage11.parse_tcp(frame)["payload"] for frame in data_frames]
        self.assertEqual(sum(len(p) for p in payloads), min(window, len(stage13.LARGE)))
        sequences = [stage11.parse_tcp(frame)["sequence"] for frame in data_frames]
        for previous, following, payload in zip(sequences, sequences[1:], payloads):
            self.assertEqual(following, previous + len(payload))


if __name__ == "__main__":
    unittest.main()
