; Backend-neutral TCP codec and transport declarations for Stage 11.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_TCP_INC
	DEFINE	_TCP_INC

TCP_PROTOCOL		EQU 6
TCP_HEADER_LENGTH	EQU 20
TCP_SYN_HEADER_LENGTH	EQU 24
; TCPX_LARGE_MSS raises the advertised receive MSS to a whole Ethernet payload.
; The receive path is charged per *segment*, not per byte: the ISA sessions,
; the frame parse, the checksum seed and the acknowledgement's own build and
; transmit all cost the same whether the segment carried 536 bytes or 1460, so
; a whole payload amortises that fixed part over 2.7x more data. It costs no
; image bytes -- only constants and the buffer geometry in memory.inc -- which
; is why it is the one throughput lever that fits DLDIRECT, WGET and FTP alike.
;
; Any client defining it needs a private receive page whose staging buffers can
; hold a whole 1,514-byte frame and whose durable queue is a whole multiple of
; the new MSS. UNET509B.DLL has neither: its queue is a single MSS-sized slot
; per channel carved out of the consumer's address space, and at 1460 that
; degenerates into a zero-window stop/start cycle. The sibling RTL8019A kit
; draws the line in exactly the same place, and for the same reason -- its
; direct clients announce 1460 while UNETRTL.DLL stays at 536.
	IFDEF TCPX_LARGE_MSS
TCP_MSS			EQU 1460
	ELSE
TCP_MSS			EQU 536
	ENDIF
TCP_RECV_MAX_SEGMENTS	EQU 5
TCP_RECV_MAX_WINDOW	EQU TCP_RECV_MAX_SEGMENTS * TCP_MSS
	IFDEF TCPX_WIDE_DIRECT_WINDOW
; DLDIRECT's receive window is paced, not sized to the card. The real-Sprinter
; matrix (specs.md, Р2) lost nothing on the internet path itself: every
; retransmission was a card RX overrun or a segment dropped behind one. The
; 3C509B keeps three full frames, the server sends its frames back to back
; 0.06 ms apart, so any burst of four overflows however fast the Z80 drains.
; Bursts come from the peer's right edge jumping -- its initial window clipped
; by ours, an ACK of two MSS releasing four frames while cwnd grows, and the
; cumulative ACK that fills a hole. Acknowledging every direct segment and
; moving the advertised right edge at most two MSS per ACK caps each release
; at two frames, so the window itself can be wider than the FIFO.
;
; The paced rerun (Р3) still lost frames while the window grew: one MSS of
; growth per ACK lets every ACK release a pair, twice what the Z80 drains, and
; the queue reaches the fourth frame. The window now starts at three MSS and
; grows one MSS per window's worth of segments sent, so pairs are rare, then
; holds at the target. Target 12 beat 9 on the same path (144 vs 104 KB/s
; without stalls): at 100 ms RTT nine MSS cap the flow near 130 KB/s.
TCP_DIRECT_WINDOW_SEGMENTS EQU 12	; target
TCP_DIRECT_INITIAL_SEGMENTS EQU 3
; The SYN, the handshake ACK and the request precede the first data ACK.
TCP_DIRECT_SETUP_SEGMENTS EQU 3
TCP_DIRECT_EDGE_STEP	EQU 2 * TCP_MSS
; A filled hole (the out-of-order queue, Р4) moves RCV.NXT past everything kept
; at once. Reopening the right edge two MSS per ACK from there sent pairs that
; overran the card on the real path within three ACKs, so the window restarts
; at what is still promised (tcp_transport.asm OOO_DRAIN).
; Growing it back one MSS per window then cost ~0.6 s per loss on the real
; path (1 -> 9 MSS in a second; 83 KB/s with 36 losses). Nothing arrives to
; clock ACKs right after the jump, so the idle wait loop opens the window
; itself: one MSS and a window update every TCP_DIRECT_PACE_POLLS polls that
; find the card empty (NETTIME quanta, ~1.9 ms each on a real Sprinter) until
; the target. The peer, holding a backlog, answers each update with one frame,
; so they arrive one round trip later spaced like updates, near the ~8 ms the
; Z80 takes per segment. A frame received restarts the count: on a short path
; data clocks the growth as before (tcp_transport.asm IDLE_OPEN). The start
; uses it too, from the first data segment: the linear start spent ~1 s under
; four MSS, where a loss has too few segments behind it for three duplicate
; ACKs and costs a retransmission timeout (2.9 s on the real path). While a
; hole is open the window does not move at all, or the ACKs stop counting as
; duplicates.
; Capping the idle reopening at half the target to keep the peer paced was a
; regression and is gone: at 100 ms RTT six MSS cap the flow near 83 KB/s
; (measured 75-77 KB/s), and a hole opening under such a window leaves the peer
; two segments behind it -- one below the three duplicate ACKs a fast
; retransmit needs. The two runs that lost anything then spent 15 s and 22 s in
; the peer's retransmission timeouts, backing off 0.3 -> 1.8 -> 7.8 s until the
; receive watchdog gave up (0x1E). At the full target eleven segments follow a
; hole and the peer retransmits within a round trip.
; That leaves the bunching this cap was aimed at: while nothing arrives the
; idle loop resends the same duplicate ACK, so three of them reach the peer
; from the segments that did arrive plus repeats, whatever its congestion
; window holds. The repeats are bounded, since after them the peer's own
; timeout is the only thing left to wait for.
TCP_DIRECT_PACE_POLLS	EQU 4
TCP_DIRECT_HOLE_ACKS	EQU 8
; SYN|ACK seeds the edge one MSS behind RCV.NXT: the handshake ACK offers one
; MSS and the request after it three, before the peer has any data to send.
TCP_DIRECT_INITIAL_EDGE	EQU (0 - TCP_MSS) & 0xFFFF
	ENDIF

; Receive window advertised while a channel is not backpressured: a whole
; multiple of TCP_MSS, since a non-multiple stalls the pipe on every window
; exhaustion (observed on the sibling RTL8019A kit's TCP stack). The win here
; is letting the peer keep more than one segment in flight instead of stopping
; and waiting for each one's ACK.
; TCP_RECV_SEGMENTS is capped by S11_PENDING_CAPACITY (memory.inc), which must
; hold a whole TCP_RECV_WINDOW so a burst can be appended, not just one MSS.
; STAGE12_LAYOUT is the key for that page space: WGET and DLSPEED reserve it
; for their single channel, FTP (which also defines it) for both of its.
;
; Five is also what the sibling kit settled on, and the ceiling is the card
; rather than the page: whatever we advertise may arrive while the application
; is busy elsewhere -- flushing its disk buffer, say -- and until READ_FRAME
; runs again it all has to sit in the 3C509B's own RX FIFO. Five segments plus
; framing is about 3 KiB against a FIFO of several, so a burst still fits.
	IFDEF UNET_DLL
; The DLL's pending queue is one real TCP_MSS per channel (BSS_PEND0/1,
; unet509b_bss.inc) regardless of STAGE12_LAYOUT's deep-window request above --
; there is no 16 KiB page to spend on a five-segment reserve here.
TCP_RECV_SEGMENTS	EQU 1
	ELSE
	IFDEF STAGE12_LAYOUT
	IFDEF TCPX_LARGE_MSS
; Two whole 1460-byte segments (2,920 bytes) is what the receive page has left
; for a durable queue once the RX/TX staging buffers grow to hold a full-size
; frame -- see memory.inc. In bytes that is slightly deeper than the five
; 536-byte segments it replaces, so the peer may still keep more than one
; segment in flight. DLDIRECT additionally overrides the advertised value from
; the card FIFO (TCPX_WIDE_DIRECT_WINDOW above); WGET and FTP advertise this
; queue's own free space, which is what SEND_SEGMENT_COMMON computes.
TCP_RECV_SEGMENTS	EQU 2
	ELSE
TCP_RECV_SEGMENTS	EQU 5
	ENDIF
	ELSE
TCP_RECV_SEGMENTS	EQU 1
	ENDIF
	ENDIF
TCP_RECV_WINDOW		EQU TCP_RECV_SEGMENTS * TCP_MSS

; Segments a directly-delivered stream may accumulate before an ACK goes out
; (RFC 1122's "at least every second segment"). Only the two-phase receive
; path coalesces: a segment that lands in the pending slot, a FIN, an RST, a
; duplicate and a closed window are all still ACKed the moment they are seen,
; and the debt is settled in full before RECV returns or the card runs dry, so
; nothing waits on a timer that does not exist here. An earlier attempt at a
; delayed ACK had to be backed out because it called the driver from inside
; PROCESS_FRAME's own call chain; this one sends from .WAIT_LOOP instead.
TCP_ACK_EVERY		EQU 2

; UNET_DLL active close, identical to UNETRTL's (sprinter-rtl8019a
; src/lib/tcp_lib.asm; tools/check-stage7.pl compares the two). A FIN that
; reached the NIC proves nothing about the peer, so CLOSE waits for the
; acknowledgement and retransmits the FIN while it does not come. The
; standalone applications keep TCPX's single FIN_TIMEOUT_MS wait.
CLOSE_ATTEMPTS		EQU 3
CLOSE_ACK_TIMEOUT_MS	EQU 500

TCP_FLAG_FIN		EQU 0x01
TCP_FLAG_SYN		EQU 0x02
TCP_FLAG_RST		EQU 0x04
TCP_FLAG_PSH		EQU 0x08
TCP_FLAG_ACK		EQU 0x10

TCP_STATE_CLOSED	EQU 0
TCP_STATE_SYN_SENT	EQU 1
TCP_STATE_ESTABLISHED	EQU 2
TCP_STATE_CLOSE_WAIT	EQU 3
TCP_STATE_FIN_WAIT	EQU 4
TCP_STATE_LISTEN	EQU 5
TCP_STATE_SYN_RECEIVED	EQU 6

TCP_ERR_TIMEOUT		EQU 30
TCP_ERR_RESET		EQU 31
TCP_ERR_CLOSED		EQU 32
TCP_ERR_WINDOW		EQU 33
TCP_ERR_SEQUENCE	EQU 34
TCP_ERR_STATE		EQU 35
; SEND suspended: the link was silent for one UNET_OPT_SENDSLICE quantum
; within the current attempt's budget. TCPX_ASYNCSEND only.
TCP_ERR_AGAIN		EQU 36

; Stable diagnostic stages published by TCPX for the application error line.
TCP_STAGE_LINK		EQU 0
TCP_STAGE_ARP		EQU 1
TCP_STAGE_SYN		EQU 2
TCP_STAGE_WINDOW	EQU 3
TCP_STAGE_DATA		EQU 4
TCP_STAGE_RECV		EQU 5
TCP_STAGE_CLOSE		EQU 6

; TCP build descriptor. Words are native little-endian pointers/values.
; Payload bytes are already stored at BUFFER + selected header length.
TCPB_BUFFER		EQU 0
TCPB_CAPACITY		EQU 2
TCPB_SOURCE_IP		EQU 4
TCPB_DESTINATION_IP	EQU 6
TCPB_SOURCE_PORT	EQU 8
TCPB_DESTINATION_PORT	EQU 10
TCPB_SEQUENCE		EQU 12	; pointer to four network-order bytes
TCPB_ACKNOWLEDGEMENT	EQU 14	; pointer to four network-order bytes
TCPB_PAYLOAD_LENGTH	EQU 16
TCPB_FLAGS		EQU 18
TCPB_WINDOW		EQU 19
TCPB_MSS		EQU 21	; zero: 20-byte header; nonzero: MSS option
TCPB_DESC_LENGTH	EQU 23

; TCP parse descriptor. Expected source port may be zero; destination may not.
TCPP_BUFFER		EQU 0
TCPP_LENGTH		EQU 2
TCPP_SOURCE_IP		EQU 4
TCPP_DESTINATION_IP	EQU 6
TCPP_EXPECT_SOURCE_PORT EQU 8
TCPP_EXPECT_DEST_PORT	EQU 10
TCPP_SEQUENCE		EQU 12	; four-byte output
TCPP_ACKNOWLEDGEMENT	EQU 16	; four-byte output
TCPP_PAYLOAD		EQU 20	; output pointer
TCPP_PAYLOAD_LENGTH	EQU 22
TCPP_FLAGS		EQU 24
TCPP_WINDOW		EQU 25
TCPP_MSS		EQU 27	; zero when absent
TCPP_HEADER_LENGTH	EQU 29
TCPP_DESC_LENGTH	EQU 30

	ENDIF
