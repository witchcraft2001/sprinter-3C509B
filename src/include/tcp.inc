; Backend-neutral TCP codec and transport declarations for Stage 11.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_TCP_INC
	DEFINE	_TCP_INC

TCP_PROTOCOL		EQU 6
TCP_HEADER_LENGTH	EQU 20
TCP_SYN_HEADER_LENGTH	EQU 24
TCP_MSS			EQU 536

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
TCP_RECV_SEGMENTS	EQU 5
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
