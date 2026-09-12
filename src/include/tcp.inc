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
; DLDIRECT reads Window 3 Free Receive Bytes once while the initialized FIFO
; is empty, and promises only what that FIFO can really hold: the window is the
; backstop for frames that arrive while the application is between RECV calls,
; and a promise the card cannot store becomes a drop and a retransmit.
	IFDEF TCPX_LARGE_MSS
; At 1460 a stored frame costs 1,516 FIFO bytes. Three need 4,548 and still fit
; the smallest legal 5 KiB RX share of an 8 KiB card -- which is also exactly
; the three-segment window the sibling kit's direct client settled on. Eight
; need 12,128 and are enabled only when the card reports at least that much.
TCP_DIRECT_RECV_SAFE_SEGMENTS EQU 3
TCP_DIRECT_RECV_WIDE_SEGMENTS EQU 8
	ELSE
; Eight maximum frames need 4,736 FIFO bytes and fit a 5 KiB RX partition;
; eleven need 6,512 and are enabled only when the card reports at least that
; much room (MAME reports its full 16 KiB RX partition).
TCP_DIRECT_RECV_SAFE_SEGMENTS EQU 8
TCP_DIRECT_RECV_WIDE_SEGMENTS EQU 11
	ENDIF
TCP_DIRECT_RECV_SAFE_WINDOW EQU TCP_DIRECT_RECV_SAFE_SEGMENTS * TCP_MSS
TCP_DIRECT_RECV_WIDE_WINDOW EQU TCP_DIRECT_RECV_WIDE_SEGMENTS * TCP_MSS
TCP_DIRECT_RECV_FIFO_FRAME EQU (14 + 20 + TCP_HEADER_LENGTH + TCP_MSS + 3) & 0xFFFC
TCP_DIRECT_RECV_WIDE_FIFO_MIN EQU TCP_DIRECT_RECV_WIDE_SEGMENTS * TCP_DIRECT_RECV_FIFO_FRAME
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
