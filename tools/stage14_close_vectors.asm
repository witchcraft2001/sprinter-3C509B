; Executable CLOSE/NETDONE vectors for UNET509B.DLL under z88dk-ticks.
; SPDX-License-Identifier: BSD-3-Clause
;
; What the peer learns when a channel closes is the whole point of CLOSE: an
; application that retries a cancelled transfer at once (SNC's WebDAV PUT, an
; FTP STOR) fails if the server still holds the first request open. UNETRTL
; 0.3.10 (sprinter-rtl8019a 2e3ec87) settled the contract; these vectors pin
; this backend to the same observable behaviour. Cases 1-8 are that commit's
; tools/test-exe-dll.js close-semantics vectors, one for one; the rest cover
; the channel bookkeeping around them (LISTEN re-arm, a listener closed with
; nothing on the wire, SEND failures that leave the connection to CLOSE, and
; NETDONE's status choice).
;
; The machine is assembled the way stage14_listen_vectors.asm assembles it:
; the shipped cold blob at 0x0000, the shipped relocated image at DLL_BASE,
; these vectors at VEC_BASE, and stubs in place of everything that needs
; hardware -- the card's transmit (CAPTURE_FRAME, which logs every TCP segment
; and plays the peer), its receive (a two-deep frame queue), the DSS clock
; (frozen) and the DSS keyboard scan (a one-key buffer). NETTIME's 1 ms pacing
; loop is stubbed out as well, so a 7-second SEND retry ladder costs 7000
; loop passes, not 7 emulated seconds. Connections are planted directly into
; the TCPX contexts: the handshake itself is covered by the listen vectors.

	DEVICE NOSLOT64K
	INCLUDE "unet.inc"		; UNET_FN_*, NERR_*, UNET_OPT_*
	INCLUDE "tcp.inc"		; TCP_FLAG_*, TCP_STATE_*, TCP_ERR_*

TEST_RESULT	EQU 0x3F00		; first failing case number, 0 = all passed
TEST_COMPLETE	EQU 0x3F01		; 0xA5 once MARK_COMPLETE was reached
TEST_CASE	EQU 0x3F02
TEST_CH		EQU 0x3F03		; channel the failing case ran on
STACK_TOP	EQU 0x3E00

CAP_BUF		EQU 0x2000		; the last frame the SEND_FRAME stub accepted
CAP_LEN		EQU 0x2800		; word
CAP_COUNT	EQU 0x2802		; TCP segments that reached the "wire"
TX_ATTEMPTS	EQU 0x2803		; every SEND_FRAME call, failed ones included
TX_FAIL_AT	EQU 0x2804		; attempt number that fails, 0 = none
ACK_DATA	EQU 0x2805		; peer: acknowledge every data segment
RST_DATA	EQU 0x2806		; peer: answer a data segment with RST
FIN_ACK_FROM	EQU 0x2807		; peer, per channel: ACK our Nth FIN and later
FINS		EQU 0x2809		; per channel: FINs the peer saw
INJECT_DATA	EQU 0x280B		; peer: channel-1 data ahead of channel 0's FIN ACK
KEY_PENDING	EQU 0x280C		; one Esc waiting in the "DSS" key buffer
CUR_CH		EQU 0x280D
PLEN		EQU 0x280E		; word, payload length of the captured segment
WIRE_STATE	EQU CAP_COUNT
WIRE_STATE_LEN	EQU CUR_CH - CAP_COUNT
PSEUDO		EQU 0x2810		; 12-byte TCP pseudo-header scratch
RX_QSRC		EQU 0x2820		; two-deep receive queue: frame and length to
RX_QLEN		EQU 0x2822		; deliver next, and the one behind it
RX_QSRC2	EQU 0x2824
RX_QLEN2	EQU 0x2826
REPLY_ACK	EQU 0x2828		; acknowledgement number of the next reply
DATA_SEQ	EQU 0x282C		; sequence number of the case's data segment
SEQ_SCRATCH	EQU 0x2830
MARK		EQU 0x2834		; CAP_COUNT before the call under test
RX_FAIL		EQU 0x2836		; non-zero: the receive poll reports this EL3 error
LOG		EQU 0x2900		; LOG_ENTRY bytes per transmitted TCP segment:
LOG_ENTRY	EQU 8			; flags, seq (4), payload length (2), src port lo
LOG_MAX		EQU 24
PEER_FRAME_A	EQU 0x2B00
PEER_FRAME_B	EQU 0x2B80
RECV_BUF	EQU 0x2C00
RECV_BUF_SIZE	EQU 256
BIG_FRAME	EQU 0x3000		; a peer segment two bytes over the MSS
BIG_PAYLOAD	EQU TCP_MSS + 2		; even, for CKSUM_ADD
BIG_FRAME_LEN	EQU 54 + BIG_PAYLOAD
RX_ISA_CODE	EQU 8			; EL3_ERR_ISA_STATE
PROTOCOL_CODE	EQU 25			; NETDRV_ERR_PROTOCOL (netdrv.inc)
TX_FAIL_CODE	EQU 13			; EL3_ERR_TX_ERROR
SEND_LEN	EQU 7

LPORT0		EQU 49200		; our end of channel 0 / 1
LPORT1		EQU 49201
PEER_PORT0	EQU 8080
PEER_PORT1	EQU 8081
LISTEN_PORT	EQU 9000

A_SEND_FRAME	EQU DLL_BASE + SYM_SEND_FRAME
A_SECONDS	EQU DLL_BASE + SYM_SECONDS
A_COLD_READY	EQU DLL_BASE + SYM_COLD_READY
A_FILL_COLD_CTX EQU DLL_BASE + SYM_FILL_COLD_CTX
A_LOCAL_IP	EQU DLL_BASE + SYM_LOCAL_IP
A_STATION_MAC	EQU DLL_BASE + SYM_STATION_MAC
A_CTX0		EQU DLL_BASE + SYM_CTX0
A_CTX1		EQU DLL_BASE + SYM_CTX1
A_INITED	EQU DLL_BASE + SYM_INITED
A_RX_PENDING	EQU DLL_BASE + SYM_RX_PENDING
A_READ_FRAME	EQU DLL_BASE + SYM_READ_FRAME
A_RX_BEGIN	EQU DLL_BASE + SYM_RX_BEGIN
A_RX_PAYLOAD	EQU DLL_BASE + SYM_RX_PAYLOAD
A_CH_STATE	EQU DLL_BASE + SYM_CH_STATE
A_LISTEN_CH	EQU DLL_BASE + SYM_LISTEN_CHANNEL
A_LISTEN_PORT	EQU DLL_BASE + SYM_LISTEN_PORT
A_LISTEN_ACC	EQU DLL_BASE + SYM_LISTEN_ACCEPTED
A_CANCEL_MODE	EQU DLL_BASE + SYM_CANCEL_MODE
A_APEND_ACTIVE	EQU DLL_BASE + SYM_APEND_ACTIVE
A_TCP_LAST	EQU DLL_BASE + SYM_TCP_LAST
A_READ_WALL	EQU DLL_BASE + SYM_READ_WALL
A_WAIT_TICK	EQU DLL_BASE + SYM_WAIT_TICK
A_CHECK_CANCEL	EQU DLL_BASE + SYM_CHECK_CANCEL
	ASSERT A_CTX1 == A_CTX0 + 40		; RESET_MACHINE clears both in one run

	MACRO ENTRY fn
	CALL	DLL_BASE + 0x20 + 3*fn
	ENDM

	MACRO CASE n
	LD	A,n
	LD	(TEST_CASE),A
	ENDM

	MACRO EXPECT_A value
	CP	value
	JP	NZ,FAIL
	ENDM

	MACRO EXPECT_BYTE at, value
	LD	A,(at)
	CP	value
	JP	NZ,FAIL
	ENDM

	; Number of logged segments whose flags intersect mask (0xFF: carrying
	; payload) must equal count.
	MACRO EXPECT_SEGMENTS mask, count
	LD	C,mask
	LD	E,0xFF
	CALL	LOG_FIND
	CP	count
	JP	NZ,FAIL
	ENDM

	ORG	0x0000
	INCBIN	"cold.bin"

	ORG	DLL_BASE
	INCBIN	"dll_image.bin"

	ORG	VEC_BASE
TEST_START
	LD	SP,STACK_TOP
	LD	A,0xFF
	LD	(TEST_RESULT),A
	XOR	A
	LD	(TEST_COMPLETE),A
	LD	(TEST_CH),A

	CASE	1
	ENTRY	UNET_FN_INIT
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	; A completed NETINIT, as the listen vectors stand one in.
	LD	A,1
	LD	(A_COLD_READY),A
	LD	(A_INITED),A
	LD	HL,LOCAL_IP
	LD	DE,A_LOCAL_IP
	LD	BC,4
	LDIR
	LD	HL,STATION_MAC
	LD	DE,A_STATION_MAC
	LD	BC,6
	LDIR
	CALL	A_FILL_COLD_CTX
	CALL	INSTALL_STUBS

	XOR	A
	CALL	CHANNEL_CASES
	LD	A,1
	CALL	CHANNEL_CASES
	XOR	A
	LD	(TEST_CH),A
	CALL	CASE_OTHER_CHANNEL_SURVIVES
	CALL	CASES_NETDONE
	CALL	CASE_BUSY
	CALL	CASE_OTHER_CHANNEL_FAULT
	CALL	CASE_RX_FAULT
	JP	PASS

CHANNEL_CASES
	LD	(CUR_CH),A
	LD	(TEST_CH),A
	CALL	CASE_ABORT_BOTH_CANDIDATES
	CALL	CASE_ABORT_FIRST_RST_LOST
	CALL	CASE_ORDERLY_FIN
	CALL	CASE_FIN_RETRANSMITTED
	CALL	CASE_FIN_UNANSWERED
	CALL	CASE_FIN_NOT_SENT
	CALL	CASE_FIN_WAIT_CANCELLED
	CALL	CASE_ACCEPTED_REARMED
	CALL	CASE_LISTENER_DROPPED
	CALL	CASE_HANDSHAKE_DROPPED
	CALL	CASE_SEND_RESET_RELEASES
	CALL	CASE_SEND_XMIT_THEN_FIN
	JP	CASE_SEND_RETRY_XMIT_THEN_ABORT

; ------------------------------------------------------
; 1. A segment transmitted but never acknowledged leaves the peer's RCV.NXT
; ambiguous, so CLOSE aborts: RST|ACK at SND.NXT and at SND.UNA, no FIN, and
; A=0 because both reached the wire.
; ------------------------------------------------------
CASE_ABORT_BOTH_CANDIDATES
	CASE	1
	CALL	FRESH_CONNECTION
	CALL	DO_SEND
	EXPECT_A NERR_SEND
	CALL	SAVE_DATA_SEQ
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 0
	EXPECT_SEGMENTS TCP_FLAG_RST, 2
	LD	E,0
	CALL	RST_ENTRY
	LD	A,SEND_LEN
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	LD	E,1
	CALL	RST_ENTRY
	XOR	A
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; 2. The first RST never left the card: the second is still attempted, and
; the lost one is reported (NERR_HW) instead of vouched for by the survivor.
CASE_ABORT_FIRST_RST_LOST
	CASE	2
	CALL	FRESH_CONNECTION
	CALL	DO_SEND
	EXPECT_A NERR_SEND
	CALL	SAVE_DATA_SEQ
	CALL	FAIL_NEXT_TRANSMIT
	CALL	DO_CLOSE
	EXPECT_A NERR_HW
	EXPECT_SEGMENTS TCP_FLAG_FIN, 0
	EXPECT_SEGMENTS TCP_FLAG_RST, 1
	LD	E,0
	CALL	RST_ENTRY
	XOR	A
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; 3. Everything acknowledged: exactly one FIN, right after the data, no RST.
CASE_ORDERLY_FIN
	CASE	3
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(ACK_DATA),A
	CALL	SET_FIN_ACK_FROM
	CALL	DO_SEND
	EXPECT_A NERR_OK
	LD	HL,SEND_LEN
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	CALL	SAVE_DATA_SEQ
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	LD	C,TCP_FLAG_FIN
	LD	E,0
	CALL	LOG_FIND
	LD	A,SEND_LEN
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; 4. The ACK of the first FIN is lost: the FIN is retransmitted with the same
; sequence number and the acknowledged retransmission is a clean close.
CASE_FIN_RETRANSMITTED
	CASE	4
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(ACK_DATA),A
	LD	A,2
	CALL	SET_FIN_ACK_FROM
	CALL	DO_SEND
	EXPECT_A NERR_OK
	CALL	SAVE_DATA_SEQ
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 2
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	LD	C,TCP_FLAG_FIN
	LD	E,0
	CALL	LOG_FIND
	LD	A,SEND_LEN
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	LD	C,TCP_FLAG_FIN
	LD	E,1
	CALL	LOG_FIND
	LD	A,SEND_LEN
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; 5. Every attempt met with silence: three FINs, no RST after them, and
; NERR_TIMEOUT -- the peer was never confirmed to have been told. The channel
; goes away regardless. With CANCELKEYS off, a key waiting in the DSS buffer
; is neither read nor taken for a cancel.
CASE_FIN_UNANSWERED
	CASE	5
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(ACK_DATA),A
	CALL	DO_SEND
	EXPECT_A NERR_OK
	LD	A,1
	LD	(KEY_PENDING),A
	CALL	DO_CLOSE
	EXPECT_A NERR_TIMEOUT
	EXPECT_SEGMENTS TCP_FLAG_FIN, 3
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	EXPECT_BYTE KEY_PENDING, 1
	EXPECT_BYTE A_TCP_LAST, TCP_ERR_TIMEOUT
	JP	EXPECT_RELEASED

; 6. The FIN never reached the wire: NERR_HW, no RST, channel released.
CASE_FIN_NOT_SENT
	CASE	6
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(ACK_DATA),A
	CALL	DO_SEND
	EXPECT_A NERR_OK
	CALL	FAIL_NEXT_TRANSMIT
	CALL	DO_CLOSE
	EXPECT_A NERR_HW
	EXPECT_SEGMENTS TCP_FLAG_FIN, 0
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	JP	EXPECT_RELEASED

; 7. CANCELKEYS armed after the SEND and an Esc still in the key buffer: the
; first tick of the FIN wait ends it. That is not an answer from the peer, so
; NERR_CANCEL, and the FIN is not retransmitted.
CASE_FIN_WAIT_CANCELLED
	CASE	7
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(ACK_DATA),A
	CALL	DO_SEND
	EXPECT_A NERR_OK
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,1
	ENTRY	UNET_FN_SETOPT
	EXPECT_A NERR_OK
	LD	A,1
	LD	(KEY_PENDING),A
	CALL	DO_CLOSE
	EXPECT_A NERR_CANCEL
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	EXPECT_BYTE KEY_PENDING, 0
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,0
	ENTRY	UNET_FN_SETOPT
	EXPECT_A NERR_OK
	JP	EXPECT_RELEASED

; 8. Channel 0's FIN wait must not cost channel 1 the reply that arrives
; during it (FTP's "226" on the control connection while the data connection
; closes): CLOSE(0) succeeds, RECV(1) returns exactly those bytes.
CASE_OTHER_CHANNEL_SURVIVES
	CASE	8
	CALL	RESET_MACHINE
	LD	A,1
	CALL	ESTABLISH
	XOR	A
	LD	(CUR_CH),A
	CALL	ESTABLISH
	LD	A,1
	LD	(ACK_DATA),A
	LD	(FIN_ACK_FROM),A
	LD	(FIN_ACK_FROM+1),A
	LD	(INJECT_DATA),A
	CALL	DO_SEND
	EXPECT_A NERR_OK
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_BYTE A_CH_STATE, 0
	EXPECT_BYTE A_CH_STATE+1, 1
	EXPECT_BYTE INJECT_DATA, 0
	LD	A,1
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,1
	ENTRY	UNET_FN_RECV
	EXPECT_A NERR_OK
	LD	HL,REPLY_226_LEN
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	LD	HL,RECV_BUF
	LD	DE,REPLY_226
	LD	B,REPLY_226_LEN
	CALL	MEMCMP
	JP	NZ,FAIL
	LD	A,1
	LD	(CUR_CH),A
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	JP	EXPECT_RELEASED

; 9. Closing the connection LISTEN accepted re-arms the listener exactly once
; on the same port (unet.inc CLOSE contract), after the same orderly close.
CASE_ACCEPTED_REARMED
	CASE	9
	CALL	FRESH_CONNECTION
	CALL	ACCEPTED_BY_LISTEN
	LD	A,1
	CALL	SET_FIN_ACK_FROM
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	CALL	CH_STATE_PTR
	LD	A,(HL)
	EXPECT_A 3
	EXPECT_BYTE A_LISTEN_ACC, 0
	LD	A,(CUR_CH)
	LD	B,A
	LD	A,(A_LISTEN_CH)
	CP	B
	JP	NZ,FAIL
	CALL	CTX_PTR
	LD	A,(IX+CTX_STATE)
	EXPECT_A TCP_STATE_LISTEN
	LD	A,(IX+CTX_LOCAL_PORT)
	EXPECT_A LOW LISTEN_PORT
	LD	A,(IX+CTX_LOCAL_PORT+1)
	EXPECT_A HIGH LISTEN_PORT
	RET

; 10. ...and closing that re-armed, never-accepted listener puts nothing on
; the wire, unarms it and frees the channel.
CASE_LISTENER_DROPPED
	CASE	10
	CALL	MARK_WIRE
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	CALL	EXPECT_WIRE_QUIET
	EXPECT_BYTE A_LISTEN_CH, 0xFF
	JP	EXPECT_RELEASED

; 11. A listener mid-handshake (SYN_RECEIVED) is dropped by NETDONE without a
; RST -- UNETRTL puts nothing on the wire for a listening channel either.
CASE_HANDSHAKE_DROPPED
	CASE	11
	CALL	RESET_MACHINE
	LD	A,(CUR_CH)
	LD	DE,LISTEN_PORT
	ENTRY	UNET_FN_LISTEN
	EXPECT_A NERR_OK
	CALL	CH_STATE_PTR
	LD	A,(HL)
	EXPECT_A 3
	CALL	CTX_PTR
	LD	(IX+CTX_STATE),TCP_STATE_SYN_RECEIVED
	CALL	MARK_WIRE
	ENTRY	UNET_FN_NETDONE
	EXPECT_A NERR_OK
	CALL	EXPECT_WIRE_QUIET
	EXPECT_BYTE A_LISTEN_CH, 0xFF
	JP	EXPECT_RELEASED

; 12. A peer RST during SEND ends the channel on the spot: NERR_CLOSED, the
; channel free and its context gone, and a later CLOSE has nothing to send.
CASE_SEND_RESET_RELEASES
	CASE	12
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(RST_DATA),A
	CALL	DO_SEND
	EXPECT_A NERR_CLOSED
	LD	A,D
	OR	E
	JP	NZ,FAIL
	CALL	EXPECT_RELEASED
	CALL	MARK_WIRE
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	CALL	EXPECT_WIRE_QUIET
	JP	EXPECT_RELEASED

; 13. A SEND whose segment never left the card keeps the connection open with
; SND.NXT back at SND.UNA, so the CLOSE that follows is an orderly FIN at the
; original sequence number, not an abort.
CASE_SEND_XMIT_THEN_FIN
	CASE	13
	CALL	FRESH_CONNECTION
	LD	A,1
	CALL	SET_FIN_ACK_FROM
	CALL	FAIL_NEXT_TRANSMIT
	CALL	DO_SEND
	EXPECT_A NERR_HW
	LD	A,D
	OR	E
	JP	NZ,FAIL
	CALL	CH_STATE_PTR
	LD	A,(HL)
	EXPECT_A 1
	CALL	CH_TABLE_PTR
	LD	DE,4
	ADD	HL,DE			; our ISN
	PUSH	HL
	LD	DE,DATA_SEQ
	LD	BC,4
	LDIR
	CALL	CTX_PTR
	LD	A,(IX+CTX_STATE)
	EXPECT_A TCP_STATE_ESTABLISHED
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	POP	DE
	LD	B,4
	CALL	MEMCMP			; SND.NXT is back at the ISN
	JP	NZ,FAIL
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	EXPECT_SEGMENTS 0xFF, 0
	LD	C,TCP_FLAG_FIN
	LD	E,0
	CALL	LOG_FIND
	XOR	A
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; 22. The first attempt went out and its ACK never came; the retransmission
; then fails on the card. The peer may well hold the bytes, so SEND (NERR_HW)
; must leave SND.NXT past them and CLOSE must abort with both RSTs -- a FIN
; here would be an old duplicate to a peer that took the segment.
CASE_SEND_RETRY_XMIT_THEN_ABORT
	CASE	22
	CALL	FRESH_CONNECTION
	LD	A,2			; the second data transmission fails
	LD	(TX_FAIL_AT),A
	CALL	DO_SEND
	EXPECT_A NERR_HW
	LD	A,D
	OR	E
	JP	NZ,FAIL
	EXPECT_SEGMENTS 0xFF, 1
	CALL	SAVE_DATA_SEQ
	CALL	CH_STATE_PTR
	LD	A,(HL)
	EXPECT_A 1
	CALL	CTX_PTR
	LD	A,(IX+CTX_STATE)
	EXPECT_A TCP_STATE_ESTABLISHED
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	EXPECT_SEGMENTS TCP_FLAG_FIN, 0
	EXPECT_SEGMENTS TCP_FLAG_RST, 2
	LD	E,0
	CALL	RST_ENTRY
	LD	A,SEND_LEN
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	LD	E,1
	CALL	RST_ENTRY
	XOR	A
	CALL	EXPECT_ENTRY_DATA_SEQ_PLUS
	JP	EXPECT_RELEASED

; ------------------------------------------------------
; 14-18. NETDONE closes both channels and reports the one that did not close
; cleanly: channel 1's status when it is not NERR_OK, otherwise channel 0's.
; Statuses are chosen, never OR-ed together.
; ------------------------------------------------------
CASES_NETDONE
	CASE	14			; 0 acknowledged, 1 silent
	LD	HL,0x0001
	LD	B,0
	LD	C,NERR_TIMEOUT
	CALL	NETDONE_COMBINATION
	CASE	15			; 0 silent, 1 acknowledged
	LD	HL,0x0100
	LD	B,0
	LD	C,NERR_TIMEOUT
	CALL	NETDONE_COMBINATION
	CASE	16			; 0 never sent its FIN, 1 silent
	LD	HL,0x0000
	LD	B,1
	LD	C,NERR_TIMEOUT
	CALL	NETDONE_COMBINATION
	CASE	17			; 0 never sent its FIN, 1 acknowledged
	LD	HL,0x0100
	LD	B,1
	LD	C,NERR_HW
	CALL	NETDONE_COMBINATION
	CASE	18			; both acknowledged
	LD	HL,0x0101
	LD	B,0
	LD	C,NERR_OK
	; fall through

; In: HL = FIN_ACK_FROM (L channel 0, H channel 1), B = TX_FAIL_AT, C = the
; NETDONE status expected. Both channels must end free.
NETDONE_COMBINATION
	PUSH	BC
	PUSH	HL
	CALL	RESET_MACHINE
	XOR	A
	CALL	ESTABLISH
	LD	A,1
	CALL	ESTABLISH
	POP	HL
	LD	(FIN_ACK_FROM),HL
	POP	BC
	LD	A,B
	LD	(TX_FAIL_AT),A
	PUSH	BC
	ENTRY	UNET_FN_NETDONE
	POP	BC
	CP	C
	JP	NZ,FAIL
	EXPECT_BYTE A_CH_STATE, 0
	EXPECT_BYTE A_CH_STATE+1, 0
	RET

; 19. A suspended SEND owns the link: CLOSE and NETDONE answer NERR_BUSY and
; touch neither the wire nor the channel.
CASE_BUSY
	CASE	19
	XOR	A
	LD	(CUR_CH),A
	CALL	FRESH_CONNECTION
	LD	A,1
	LD	(A_APEND_ACTIVE),A
	CALL	DO_CLOSE
	EXPECT_A NERR_BUSY
	ENTRY	UNET_FN_NETDONE
	EXPECT_A NERR_BUSY
	EXPECT_BYTE CAP_COUNT, 0
	EXPECT_BYTE A_CH_STATE, 1
	XOR	A
	LD	(A_APEND_ACTIVE),A
	RET

; 20. A frame for the OTHER channel that its context rejects (a segment over
; the MSS: HANDLE_SEGMENT fails that context with NETDRV_ERR_PROTOCOL) ends
; channel 0's FIN wait with an error and IX still on channel 1. CLOSE must
; report NERR_TIMEOUT for channel 0 and release channel 0's context -- not
; channel 1's, whose diagnostic must survive.
CASE_OTHER_CHANNEL_FAULT
	CASE	20
	CALL	RESET_MACHINE
	LD	A,1
	CALL	ESTABLISH
	XOR	A
	LD	(CUR_CH),A
	CALL	ESTABLISH
	CALL	BUILD_BIG_SEGMENT
	LD	HL,BIG_FRAME
	LD	(RX_QSRC),HL
	LD	HL,BIG_FRAME_LEN
	LD	(RX_QLEN),HL
	CALL	DO_CLOSE
	EXPECT_A NERR_TIMEOUT
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	EXPECT_BYTE A_TCP_LAST, TCP_ERR_TIMEOUT
	CALL	EXPECT_RELEASED
	EXPECT_BYTE A_CH_STATE+1, 1
	EXPECT_BYTE A_CTX1 + CTX_LAST_STATUS, PROTOCOL_CODE
	EXPECT_BYTE A_CTX1 + CTX_REMOTE_PORT, LOW PEER_PORT1
	; channel 1's own close then finds a context the fault already closed
	LD	A,1
	LD	(CUR_CH),A
	CALL	MARK_WIRE
	CALL	DO_CLOSE
	EXPECT_A NERR_OK
	CALL	EXPECT_WIRE_QUIET
	JP	EXPECT_RELEASED

; 21. A card error on the receive side during the FIN wait has no UNETRTL
; counterpart; it is reported as NERR_TIMEOUT (nothing the peer said was
; seen), with the raw wait status in LASTERR's tcp field.
CASE_RX_FAULT
	CASE	21
	XOR	A
	LD	(CUR_CH),A
	CALL	FRESH_CONNECTION
	LD	A,RX_ISA_CODE
	LD	(RX_FAIL),A
	CALL	DO_CLOSE
	PUSH	AF
	XOR	A
	LD	(RX_FAIL),A
	POP	AF
	EXPECT_A NERR_TIMEOUT
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	ENTRY	UNET_FN_LASTERR
	EXPECT_A NERR_OK
	LD	HL,RECV_BUF
	LD	DE,LASTERR_CLOSE_TIMEOUT
	LD	B,43
	CALL	MEMCMP
	JP	NZ,FAIL
	EXPECT_SEGMENTS TCP_FLAG_FIN, 1
	EXPECT_SEGMENTS TCP_FLAG_RST, 0
	JP	EXPECT_RELEASED

; ======================================================
; Machine set-up
; ======================================================
INSTALL_STUBS
	LD	A,0xAF			; S9APP.SECONDS: XOR A / RET
	LD	(A_SECONDS),A
	LD	A,0xC9
	LD	(A_SECONDS+1),A
	LD	A,0xC3
	LD	(A_SEND_FRAME),A
	LD	HL,CAPTURE_FRAME
	LD	(A_SEND_FRAME+1),HL
	LD	A,0xC3
	LD	(A_RX_PENDING),A
	LD	HL,RX_PENDING_STUB
	LD	(A_RX_PENDING+1),HL
	LD	A,0xC3
	LD	(A_READ_FRAME),A
	LD	HL,READ_FRAME_STUB
	LD	(A_READ_FRAME+1),HL
	LD	A,0xC3
	LD	(A_RX_BEGIN),A
	LD	HL,RX_BEGIN_STUB
	LD	(A_RX_BEGIN+1),HL
	LD	A,0xC3
	LD	(A_RX_PAYLOAD),A
	LD	HL,RX_PAYLOAD_STUB
	LD	(A_RX_PAYLOAD+1),HL
	LD	A,0x21			; NETTIME.READ_WALL: LD HL,0 / RET
	LD	(A_READ_WALL),A
	LD	HL,0
	LD	(A_READ_WALL+1),HL
	LD	A,0xC9
	LD	(A_READ_WALL+3),A
	LD	A,0xAF			; S7APP.WAIT_TICK: XOR A / RET
	LD	(A_WAIT_TICK),A
	LD	A,0xC9
	LD	(A_WAIT_TICK+1),A
	; TCPX.CHECK_CANCEL stays live -- its CANCELKEYS gate is under test --
	; and only its DSS key scan is replaced. The bytes are checked first, so
	; a reshuffled routine fails loudly instead of patching the wrong code.
	LD	HL,A_CHECK_CANCEL+5
	LD	A,(HL)
	CP	0x0E			; LD C,DSS_SCANKEY
	JP	NZ,FAIL
	INC	HL
	INC	HL
	LD	A,(HL)
	CP	0xD7			; RST DSS
	JP	NZ,FAIL
	LD	HL,A_CHECK_CANCEL+5
	LD	(HL),0xCD		; CALL SCANKEY_STUB
	INC	HL
	LD	DE,SCANKEY_STUB
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

; RESET_MACHINE: both channels free and their contexts empty, no listener,
; CANCELKEYS off, an idle wire and a peer that says nothing.
RESET_MACHINE
	LD	HL,WIRE_STATE
	LD	B,WIRE_STATE_LEN
.wire
	LD	(HL),0
	INC	HL
	DJNZ	.wire
	LD	HL,0
	LD	(RX_QLEN),HL
	LD	(RX_QLEN2),HL
	LD	HL,A_CTX0
	LD	B,80			; both contexts
.contexts
	LD	(HL),0
	INC	HL
	DJNZ	.contexts
	XOR	A
	LD	(A_CH_STATE),A
	LD	(A_CH_STATE+1),A
	LD	(A_LISTEN_ACC),A
	LD	(A_CANCEL_MODE),A
	LD	(A_APEND_ACTIVE),A
	DEC	A
	LD	(A_LISTEN_CH),A
	RET

FRESH_CONNECTION
	CALL	RESET_MACHINE
	LD	A,(CUR_CH)
	; fall through

; ESTABLISH: plant an established connection on channel A. In: A=channel.
ESTABLISH
	PUSH	AF
	CALL	CTX_PTR_A
	LD	(IX+CTX_STATE),TCP_STATE_ESTABLISHED
	PUSH	IX
	POP	HL
	LD	DE,CTX_REMOTE_IP
	ADD	HL,DE
	EX	DE,HL
	LD	HL,PEER_IP
	LD	BC,4
	LDIR
	PUSH	IX
	POP	HL
	LD	DE,CTX_REMOTE_MAC
	ADD	HL,DE
	EX	DE,HL
	LD	HL,PEER_MAC
	LD	BC,6
	LDIR
	POP	AF
	PUSH	AF
	CALL	CH_TABLE_PTR_A		; HL = peer port BE, local port BE, ISN, peer ISN
	LD	A,(HL)
	LD	(IX+CTX_REMOTE_PORT+1),A
	INC	HL
	LD	A,(HL)
	LD	(IX+CTX_REMOTE_PORT),A
	INC	HL
	LD	A,(HL)
	LD	(IX+CTX_LOCAL_PORT+1),A
	INC	HL
	LD	A,(HL)
	LD	(IX+CTX_LOCAL_PORT),A
	INC	HL
	PUSH	HL
	CALL	.field
	DB	CTX_SND_UNA
	POP	HL
	PUSH	HL
	CALL	.field
	DB	CTX_SND_NXT
	POP	HL
	LD	BC,4
	ADD	HL,BC
	CALL	.field
	DB	CTX_RCV_NXT
	LD	(IX+CTX_PEER_MSS),LOW TCP_MSS
	LD	(IX+CTX_PEER_MSS+1),HIGH TCP_MSS
	LD	(IX+CTX_REMOTE_WINDOW),0xFF
	LD	(IX+CTX_REMOTE_WINDOW+1),0xFF
	POP	AF
	CALL	CH_STATE_PTR_A
	LD	(HL),1
	RET
; copy the 4 bytes at HL into the context field whose offset follows the CALL
.field
	EX	(SP),HL			; HL = offset byte, stack = source
	LD	E,(HL)
	INC	HL
	EX	(SP),HL			; return past the offset, HL = source
	LD	D,0
	PUSH	HL
	PUSH	IX
	POP	HL
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	LD	BC,4
	LDIR
	RET

; ACCEPTED_BY_LISTEN: mark CUR_CH's planted connection as the one LISTEN on
; LISTEN_PORT accepted.
ACCEPTED_BY_LISTEN
	LD	A,(CUR_CH)
	LD	(A_LISTEN_CH),A
	LD	HL,LISTEN_PORT
	LD	(A_LISTEN_PORT),HL
	LD	A,1
	LD	(A_LISTEN_ACC),A
	RET

; SET_FIN_ACK_FROM: the peer acknowledges CUR_CH's Nth FIN on. In: A=N.
SET_FIN_ACK_FROM
	PUSH	AF
	LD	A,(CUR_CH)
	LD	E,A
	LD	D,0
	LD	HL,FIN_ACK_FROM
	ADD	HL,DE
	POP	AF
	LD	(HL),A
	RET

FAIL_NEXT_TRANSMIT
	LD	A,(TX_ATTEMPTS)
	INC	A
	LD	(TX_FAIL_AT),A
	RET

CTX_PTR
	LD	A,(CUR_CH)
CTX_PTR_A
	LD	IX,A_CTX0
	OR	A
	RET	Z
	LD	IX,A_CTX1
	RET

CH_STATE_PTR
	LD	A,(CUR_CH)
CH_STATE_PTR_A
	LD	HL,A_CH_STATE
	OR	A
	RET	Z
	INC	HL
	RET

CH_TABLE_PTR
	LD	A,(CUR_CH)
CH_TABLE_PTR_A
	LD	HL,CH_TABLE0
	OR	A
	RET	Z
	LD	HL,CH_TABLE1
	RET

DO_SEND
	LD	A,(CUR_CH)
	LD	DE,SEND_PAYLOAD
	LD	IX,SEND_LEN
	ENTRY	UNET_FN_SEND
	RET

DO_CLOSE
	LD	A,(CUR_CH)
	ENTRY	UNET_FN_CLOSE
	RET

; ======================================================
; Checks
; ======================================================
; EXPECT_RELEASED: CUR_CH is free and its TCPX context closed.
EXPECT_RELEASED
	CALL	CH_STATE_PTR
	LD	A,(HL)
	EXPECT_A 0
	CALL	CTX_PTR
	LD	A,(IX+CTX_STATE)
	EXPECT_A TCP_STATE_CLOSED
	RET

MARK_WIRE
	LD	A,(CAP_COUNT)
	LD	(MARK),A
	LD	A,(TX_ATTEMPTS)
	LD	(MARK+1),A
	RET

; EXPECT_WIRE_QUIET: not one transmit attempt since MARK_WIRE.
EXPECT_WIRE_QUIET
	LD	A,(MARK+1)
	LD	B,A
	LD	A,(TX_ATTEMPTS)
	CP	B
	JP	NZ,FAIL
	RET

; SAVE_DATA_SEQ: DATA_SEQ = sequence number of the first logged data segment.
SAVE_DATA_SEQ
	LD	C,0xFF
	LD	E,0
	CALL	LOG_FIND
	JP	C,FAIL
	INC	HL
	LD	DE,DATA_SEQ
	LD	BC,4
	LDIR
	RET

; RST_ENTRY: HL = the E-th RST logged (0-based), which must be exactly
; RST|ACK. In: E.
RST_ENTRY
	LD	C,TCP_FLAG_RST
	CALL	LOG_FIND
	JP	C,FAIL
	LD	A,(HL)
	CP	TCP_FLAG_RST|TCP_FLAG_ACK
	JP	NZ,FAIL
	RET

; EXPECT_ENTRY_DATA_SEQ_PLUS: the logged segment at HL carries sequence
; number DATA_SEQ + A.
EXPECT_ENTRY_DATA_SEQ_PLUS
	PUSH	HL
	LD	HL,DATA_SEQ
	LD	DE,SEQ_SCRATCH
	LD	BC,4
	LDIR
	LD	HL,SEQ_SCRATCH+3
	ADD	A,(HL)
	LD	(HL),A
	LD	B,3
.carry
	DEC	HL
	LD	A,(HL)
	ADC	A,0
	LD	(HL),A
	DJNZ	.carry
	POP	HL
	INC	HL
	LD	DE,SEQ_SCRATCH
	LD	B,4
	CALL	MEMCMP
	JP	NZ,FAIL
	RET

; LOG_FIND: In C = flag mask (0xFF: segments carrying payload), E = index
; among the matching segments. Out: CF=0 and HL = that log entry; or CF=1
; with A = the number of matches (E=0xFF counts them).
LOG_FIND
	LD	HL,LOG
	LD	D,0
	LD	A,(CAP_COUNT)
	OR	A
	JR	Z,.done
	LD	B,A
.loop
	LD	A,C
	CP	0xFF
	JR	Z,.payload
	AND	(HL)
	JR	Z,.next
	JR	.match
.payload
	PUSH	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	INC	HL
	LD	A,(HL)
	INC	HL
	OR	(HL)
	POP	HL
	JR	Z,.next
.match
	LD	A,D
	CP	E
	RET	Z			; CF=0
	INC	D
.next
	PUSH	DE
	LD	DE,LOG_ENTRY
	ADD	HL,DE
	POP	DE
	DJNZ	.loop
.done
	LD	A,D
	SCF
	RET

; ======================================================
; The wire
; ======================================================
; CAPTURE_FRAME stands in for NETDRV.SEND_FRAME: In HL=frame, BC=length.
; Out: CF=0/A=0, or CF=1/A=TX_FAIL_CODE on the attempt TX_FAIL_AT names --
; a frame that never went out is not logged and not answered.
CAPTURE_FRAME
	LD	A,(TX_ATTEMPTS)
	INC	A
	LD	(TX_ATTEMPTS),A
	LD	E,A
	LD	A,(TX_FAIL_AT)
	CP	E
	JR	NZ,.transmit
	LD	A,TX_FAIL_CODE
	SCF
	RET
.transmit
	LD	(CAP_LEN),BC
	LD	DE,CAP_BUF
	LDIR
	LD	A,(CAP_BUF+23)
	CP	6			; IPv4 protocol TCP
	JR	NZ,.quiet
	LD	A,(CAP_COUNT)
	CP	LOG_MAX
	JP	NC,FAIL
	LD	L,A
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	DE,LOG
	ADD	HL,DE
	LD	A,(CAP_BUF+47)
	LD	(HL),A
	INC	HL
	EX	DE,HL
	LD	HL,CAP_BUF+38
	LD	BC,4
	LDIR
	; payload = IPv4 total length - 40: a short frame may be padded
	LD	A,(CAP_BUF+16)
	LD	H,A
	LD	A,(CAP_BUF+17)
	LD	L,A
	LD	BC,-40
	ADD	HL,BC
	LD	(PLEN),HL
	EX	DE,HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	A,(CAP_BUF+35)
	LD	(HL),A
	LD	HL,CAP_COUNT
	INC	(HL)
	CALL	PEER_REACTS
.quiet
	XOR	A
	RET

; PEER_REACTS: the scripted peer's answer to the segment in CAP_BUF.
PEER_REACTS
	LD	A,(CAP_BUF+35)
	SUB	LOW LPORT0
	LD	C,A			; channel
	LD	HL,(PLEN)
	LD	A,H
	OR	L
	JR	Z,.control
	EX	DE,HL
	CALL	ACK_CAPTURED_PLUS
	LD	A,(RST_DATA)
	OR	A
	LD	B,TCP_FLAG_RST|TCP_FLAG_ACK
	JR	NZ,.reply
	LD	A,(ACK_DATA)
	OR	A
	RET	Z
	LD	B,TCP_FLAG_ACK
.reply
	LD	A,C
	LD	C,0
	JP	QUEUE_REPLY
.control
	LD	A,(CAP_BUF+47)
	AND	TCP_FLAG_FIN
	RET	Z
	LD	B,0
	LD	HL,FINS
	ADD	HL,BC
	INC	(HL)
	LD	A,(HL)
	LD	HL,FIN_ACK_FROM
	ADD	HL,BC
	LD	E,(HL)
	INC	E
	DEC	E
	RET	Z			; this channel's peer never answers a FIN
	CP	E
	RET	C			; nor this early one
	PUSH	BC
	LD	A,(INJECT_DATA)
	OR	A
	JR	Z,.fin_ack
	XOR	A
	LD	(INJECT_DATA),A
	; Channel-1 data, acknowledging exactly what channel 1 has sent, lands
	; in the queue ahead of the FIN's ACK: it arrives DURING the wait.
	LD	A,1
	CALL	CTX_PTR_A
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	LD	DE,REPLY_ACK
	LD	BC,4
	LDIR
	LD	A,1
	LD	B,TCP_FLAG_PSH|TCP_FLAG_ACK
	LD	C,REPLY_226_LEN
	LD	DE,REPLY_226
	CALL	QUEUE_REPLY
.fin_ack
	LD	DE,1
	CALL	ACK_CAPTURED_PLUS
	POP	BC
	LD	A,C
	LD	B,TCP_FLAG_ACK
	LD	C,0
	JP	QUEUE_REPLY

; ACK_CAPTURED_PLUS: REPLY_ACK = the captured segment's sequence number + DE.
; Preserves BC.
ACK_CAPTURED_PLUS
	PUSH	BC
	LD	HL,CAP_BUF+38
	PUSH	DE
	LD	DE,REPLY_ACK
	LD	BC,4
	LDIR
	POP	DE
	LD	HL,REPLY_ACK+3
	LD	A,(HL)
	ADD	A,E
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	ADC	A,D
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	ADC	A,0
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	ADC	A,0
	LD	(HL),A
	POP	BC
	RET

; QUEUE_REPLY: build a peer segment and queue it for the receive stubs.
; In: A=channel, B=flags, C=payload length (even), DE=payload,
; REPLY_ACK=acknowledgement number. The sequence number is the context's own
; RCV.NXT, i.e. in order.
QUEUE_REPLY
	PUSH	DE
	PUSH	BC
	PUSH	AF
	LD	IY,PEER_FRAME_A
	LD	HL,(RX_QLEN)
	LD	A,H
	OR	L
	JR	Z,.buffer
	LD	HL,(RX_QSRC)
	LD	DE,PEER_FRAME_A
	OR	A
	SBC	HL,DE
	JR	NZ,.buffer
	LD	IY,PEER_FRAME_B
.buffer
	LD	HL,FRAME_TEMPLATE
	PUSH	IY
	POP	DE
	LD	BC,FRAME_TEMPLATE_LEN
	LDIR
	POP	AF
	PUSH	AF
	CALL	CH_TABLE_PTR_A
	LD	A,(HL)
	LD	(IY+34),A
	INC	HL
	LD	A,(HL)
	LD	(IY+35),A
	INC	HL
	LD	A,(HL)
	LD	(IY+36),A
	INC	HL
	LD	A,(HL)
	LD	(IY+37),A
	POP	AF
	CALL	CTX_PTR_A
	LD	DE,CTX_RCV_NXT
	PUSH	IX
	POP	HL
	ADD	HL,DE
	PUSH	IY
	POP	DE
	LD	A,38
	ADD	A,E
	LD	E,A
	LD	A,D
	ADC	A,0
	LD	D,A
	LD	BC,4
	LDIR				; sequence
	LD	HL,REPLY_ACK
	LD	BC,4
	LDIR				; acknowledgement
	POP	BC
	LD	(IY+47),B
	LD	A,40
	ADD	A,C
	LD	(IY+17),A
	POP	HL			; payload
	LD	A,C
	OR	A
	JR	Z,.no_payload
	PUSH	IY
	POP	DE
	PUSH	HL
	LD	HL,FRAME_TEMPLATE_LEN
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	LD	B,0
	LDIR
.no_payload
	PUSH	IY
	CALL	FIX_IP_CKSUM
	POP	IY
	PUSH	IY
	CALL	FIX_TCP_CKSUM
	POP	IY
	LD	A,(IY+17)
	ADD	A,14
	LD	L,A
	LD	H,0
	LD	DE,(RX_QLEN)
	LD	A,D
	OR	E
	JR	NZ,.second
	LD	(RX_QSRC),IY
	LD	(RX_QLEN),HL
	RET
.second
	LD	(RX_QSRC2),IY
	LD	(RX_QLEN2),HL
	RET

; BUILD_BIG_SEGMENT: a PSH|ACK segment for channel 1, in order and fully
; acknowledging channel 1's sends, carrying one byte more than the MSS.
BUILD_BIG_SEGMENT
	LD	HL,FRAME_TEMPLATE
	LD	DE,BIG_FRAME
	LD	BC,FRAME_TEMPLATE_LEN
	LDIR
	LD	B,BIG_PAYLOAD & 0xFF
	LD	C,BIG_PAYLOAD >> 8
	INC	C
	LD	A,'x'
.fill
	LD	(DE),A
	INC	DE
	DJNZ	.fill
	DEC	C
	JR	NZ,.fill
	LD	IY,BIG_FRAME
	LD	HL,CH_TABLE1
	LD	A,(HL)
	LD	(IY+34),A
	INC	HL
	LD	A,(HL)
	LD	(IY+35),A
	INC	HL
	LD	A,(HL)
	LD	(IY+36),A
	INC	HL
	LD	A,(HL)
	LD	(IY+37),A
	LD	A,1
	CALL	CTX_PTR_A
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	LD	DE,BIG_FRAME+38
	LD	BC,4
	LDIR
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	LD	DE,BIG_FRAME+42
	LD	BC,4
	LDIR
	LD	(IY+47),TCP_FLAG_PSH|TCP_FLAG_ACK
	LD	(IY+16),HIGH (40 + BIG_PAYLOAD)
	LD	(IY+17),LOW (40 + BIG_PAYLOAD)
	CALL	FIX_IP_CKSUM
	LD	IY,BIG_FRAME
	JP	FIX_TCP_CKSUM

; SCANKEY_STUB replaces DSS_SCANKEY inside TCPX.CHECK_CANCEL: Z when the
; buffer is empty, otherwise NZ with E=Esc, and the key is consumed.
SCANKEY_STUB
	LD	A,(KEY_PENDING)
	OR	A
	RET	Z
	XOR	A
	LD	(KEY_PENDING),A
	LD	B,A
	LD	D,A
	LD	E,0x1B
	INC	A
	RET

RX_PENDING_STUB
	LD	A,(RX_QLEN)
	LD	HL,RX_QLEN+1
	OR	(HL)
	RET	Z
	LD	A,1
	OR	A
	RET

READ_FRAME_STUB
	EX	DE,HL
	LD	HL,(RX_QSRC)
	LD	BC,(RX_QLEN)
	PUSH	BC
	LDIR
	CALL	PROMOTE_QUEUE
	POP	BC
	XOR	A
	RET

RX_BEGIN_STUB
	LD	A,(RX_FAIL)
	OR	A
	JR	Z,.poll
	SCF
	RET
.poll
	PUSH	HL
	LD	HL,(RX_QLEN)
	LD	A,H
	OR	L
	JR	Z,.none
	POP	DE
	LD	HL,(RX_QSRC)
	LDIR
	LD	BC,(RX_QLEN)
	XOR	A
	RET
.none
	POP	HL
	LD	BC,0
	XOR	A
	RET

RX_PAYLOAD_STUB
	LD	A,B
	OR	C
	JR	Z,PROMOTE_QUEUE
	LD	HL,(RX_QSRC)
	PUSH	DE
	LD	DE,FRAME_TEMPLATE_LEN
	ADD	HL,DE
	POP	DE
	LDIR
PROMOTE_QUEUE
	LD	HL,(RX_QSRC2)
	LD	(RX_QSRC),HL
	LD	HL,(RX_QLEN2)
	LD	(RX_QLEN),HL
	LD	HL,0
	LD	(RX_QLEN2),HL
	XOR	A
	RET

; FIX_TCP_CKSUM: In IY = an optionless IPv4/TCP frame with an even TCP
; length. Recomputes the TCP checksum. Clobbers AF/BC/DE/HL/IX.
FIX_TCP_CKSUM
	XOR	A
	LD	(IY+50),A
	LD	(IY+51),A
	PUSH	IY
	POP	HL
	LD	DE,26
	ADD	HL,DE
	LD	DE,PSEUDO
	LD	BC,8
	LDIR
	XOR	A
	LD	(PSEUDO+8),A
	LD	A,6
	LD	(PSEUDO+9),A
	LD	H,(IY+16)
	LD	L,(IY+17)
	LD	BC,20
	OR	A
	SBC	HL,BC			; TCP length = IPv4 total - fixed header
	LD	A,H
	LD	(PSEUDO+10),A
	LD	A,L
	LD	(PSEUDO+11),A
	PUSH	HL
	LD	HL,0
	LD	IX,PSEUDO
	LD	BC,12
	CALL	CKSUM_ADD
	PUSH	IY
	POP	IX
	LD	BC,34
	ADD	IX,BC
	POP	BC
	CALL	CKSUM_ADD
	LD	A,H
	CPL
	LD	(IY+50),A
	LD	A,L
	CPL
	LD	(IY+51),A
	RET

; FIX_IP_CKSUM: In IY = frame. Recomputes the fixed 20-byte IPv4 header sum.
FIX_IP_CKSUM
	XOR	A
	LD	(IY+24),A
	LD	(IY+25),A
	LD	HL,0
	PUSH	IY
	POP	IX
	LD	BC,14
	ADD	IX,BC
	LD	BC,20
	CALL	CKSUM_ADD
	LD	A,H
	CPL
	LD	(IY+24),A
	LD	A,L
	CPL
	LD	(IY+25),A
	RET

CKSUM_ADD
	LD	A,B
	OR	C
	RET	Z
	LD	D,(IX+0)
	LD	E,(IX+1)
	INC	IX
	INC	IX
	ADD	HL,DE
	JR	NC,.no_carry
	INC	HL
.no_carry
	DEC	BC
	DEC	BC
	JR	CKSUM_ADD

; MEMCMP: Z if the B bytes at HL and DE are identical. Clobbers AF/B/DE/HL.
MEMCMP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	HL
	INC	DE
	DJNZ	MEMCMP
	RET

PASS
	XOR	A
	LD	(TEST_RESULT),A
	JR	MARK_COMPLETE
FAIL
	LD	A,(TEST_CASE)
	LD	(TEST_RESULT),A
MARK_COMPLETE
	LD	A,0xA5
	LD	(TEST_COMPLETE),A
TEST_DONE				; z88dk-ticks stops when PC reaches this address
	JR	TEST_DONE

SEND_PAYLOAD	DB "request"
REPLY_226	DB "226 Transfer complete.",13,10
REPLY_226_LEN	EQU $ - REPLY_226
LASTERR_CLOSE_TIMEOUT DB "509B hw=1 st=05 nerr=0C tcp=1E el3=00/0000",0
	ASSERT (REPLY_226_LEN & 1) == 0

STATION_MAC	DB 0x02,0x60,0x8C,0x11,0x22,0x33
PEER_MAC	DB 0x02,0xAA,0xBB,0xCC,0xDD,0xEE
LOCAL_IP	DB 192,168,1,148
PEER_IP		DB 192,168,1,36

; Per channel: peer port, our port (both big-endian), our ISN, the peer's ISN.
; The ISNs sit next to a byte carry, so +7 and +1 have to ripple.
CH_TABLE0	DB HIGH PEER_PORT0, LOW PEER_PORT0, HIGH LPORT0, LOW LPORT0
		DB 0x01,0x00,0xFF,0xFE, 0x11,0x22,0x33,0x44
CH_TABLE1	DB HIGH PEER_PORT1, LOW PEER_PORT1, HIGH LPORT1, LOW LPORT1
		DB 0x7F,0xFF,0xFF,0xFF, 0x55,0x66,0x77,0x88

; A peer segment: 192.168.1.36 -> 192.168.1.148, ACK, window 0xFFFF. Ports,
; numbers, flags, length and both checksums are filled in by QUEUE_REPLY.
FRAME_TEMPLATE
	DB	0x02,0x60,0x8C,0x11,0x22,0x33,0x02,0xAA,0xBB,0xCC,0xDD,0xEE
	DB	0x08,0x00,0x45,0x00,0x00,0x28,0xBE,0xF1,0x40,0x00,0x40,0x06
	DB	0x00,0x00,0xC0,0xA8,0x01,0x24,0xC0,0xA8,0x01,0x94,0x00,0x00
	DB	0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x50,0x10
	DB	0xFF,0xFF,0x00,0x00,0x00,0x00
FRAME_TEMPLATE_LEN EQU $ - FRAME_TEMPLATE
	ASSERT FRAME_TEMPLATE_LEN == 54

	SAVEBIN "close_vectors.bin",0,0x10000
