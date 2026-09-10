; Executable passive-open (LISTEN) vectors for UNET509B.DLL under z88dk-ticks.
; SPDX-License-Identifier: BSD-3-Clause
;
; Why this file exists as a third vector run instead of a few more cases in
; stage14_vectors.asm: TCPX_LISTEN is compiled into the DLL build ONLY -- no
; EXE in this kit defines it -- so until now not one automated test executed
; a single instruction of the passive-open path, and the manual Sprinter run
; is the only thing that ever exercised it. stage14_vectors.asm cannot reach
; it either: it deliberately restricts itself to entry points that need
; neither the card nor the cold overlay, while a SYN has to be parsed and a
; SYN|ACK built, and in this build all four of those codecs are cold
; trampolines.
;
; So this run assembles the whole machine: the SHIPPED cold blob at 0x0000
; (its real ORG -- COLD.RUN's port writes are inert under ticks, and the
; blob simply stays visible, which is exactly what a successful remap would
; have produced), the SHIPPED relocated image at 0x4000, and the vectors at
; 0x8000. Two hot routines are patched out because they are the only ones on
; this path that need a machine: S9APP.SECONDS (RST into DSS, called by
; GENERATE_TUPLE for ISN entropy) and NETDRV.SEND_FRAME (ISA), the latter
; replaced by a capture stub so the emitted frame can be inspected byte for
; byte, checksums included. The cases that call RECV rather than
; PROCESS_FRAME need three more: NETDRV.RX_PENDING and NETDRV.READ_FRAME
; become a two-deep frame queue, NETTIME.READ_WALL (its own RST, not the
; S9APP one) freezes at zero, and TCPX.CHECK_CANCEL answers "no key" instead
; of asking DSS on every pass of the wait loop.
;
; The frame fed in is a real macOS-shaped SYN: 20 bytes of options (MSS,
; window scale, timestamps), ECN bits absent, both checksums valid.

	DEVICE NOSLOT64K
	INCLUDE "unet.inc"		; UNET_FN_* (frozen ABI constants)
	INCLUDE "tcp.inc"		; TCP_FLAG_*, TCP_STATE_*

; The context field offsets and the event bit are private to
; tcp_transport.asm; test-stage14-asm.sh passes them in from the build's own
; symbols, so a context reshuffle cannot leave these vectors reading stale
; addresses and silently passing.

TEST_RESULT	EQU 0x3F00		; first failing case number, 0 = all passed
TEST_COMPLETE	EQU 0x3F01		; 0xA5 once MARK_COMPLETE was reached
TEST_CASE	EQU 0x3F02
STACK_TOP	EQU 0x3E00

CAP_BUF		EQU 0x2000		; what the SEND_FRAME stub captured
CAP_LEN		EQU 0x2800		; word
CAP_COUNT	EQU 0x2802		; byte, frames the stub saw
PSEUDO		EQU 0x2810		; 12-byte TCP pseudo-header scratch
RX_QSRC		EQU 0x2820		; two-deep queue for the READ_FRAME stub:
RX_QLEN		EQU 0x2822		; source/length of the frame to deliver next
RX_QSRC2	EQU 0x2824		; and of the one behind it (0 length = empty)
RX_QLEN2	EQU 0x2826
ACK_FRAME	EQU 0x2900		; the handshake's closing ACK, built here
FIN_FRAME	EQU 0x2940		; the peer's FIN|ACK
FINACK_FRAME	EQU 0x2980		; its acknowledgement of our own FIN
DATA_ACK_FRAME	EQU 0x29C0		; the peer's ACK of the bytes we SEND
SEND_LEN	EQU 4			; payload the SEND case transmits
RECV_BUF	EQU 0x2C00		; a consumer buffer outside the DLL's window
RECV_BUF_SIZE	EQU 512

DLL_BASE	EQU 0x4000
VEC_BASE	EQU 0x8000

; Addresses inside the relocated image. The .sym values come from the
; stand-alone ORG 0x0020 assembly of the same source, and the image loads at
; DLL_BASE+0x20, so an image address is simply DLL_BASE + the symbol.
A_PROCESS_FRAME	EQU DLL_BASE + SYM_PROCESS_FRAME
A_SEND_FRAME	EQU DLL_BASE + SYM_SEND_FRAME
A_SECONDS	EQU DLL_BASE + SYM_SECONDS
A_COLD_READY	EQU DLL_BASE + SYM_COLD_READY
A_LOCAL_IP	EQU DLL_BASE + SYM_LOCAL_IP
A_STATION_MAC	EQU DLL_BASE + SYM_STATION_MAC
A_RX_BUF	EQU DLL_BASE + SYM_RX_BUF
A_FRAME_LEN	EQU DLL_BASE + SYM_FRAME_LEN
A_CTX0		EQU DLL_BASE + SYM_CTX0
A_INITED	EQU DLL_BASE + SYM_INITED
A_RX_PENDING	EQU DLL_BASE + SYM_RX_PENDING
A_READ_FRAME	EQU DLL_BASE + SYM_READ_FRAME
A_CH_STATE	EQU DLL_BASE + SYM_CH_STATE
A_LISTEN_ACC	EQU DLL_BASE + SYM_LISTEN_ACCEPTED
A_READ_WALL	EQU DLL_BASE + SYM_READ_WALL
A_CHECK_CANCEL	EQU DLL_BASE + SYM_CHECK_CANCEL

LISTEN_PORT	EQU 9000
PEER_PORT	EQU 50000
SYNACK_LEN	EQU 14 + 20 + 24	; MSS is the only option we emit

	MACRO ENTRY fn
	CALL	DLL_BASE + 0x20 + 3*fn
	ENDM

	MACRO CASE n
	LD	A,n
	LD	(TEST_CASE),A
	ENDM

	; HL=actual, DE=expected, count bytes
	MACRO EXPECT_MEM here, there, count
	LD	HL,here
	LD	DE,there
	LD	B,count
	CALL	MEMCMP
	JP	NZ,FAIL
	ENDM

	MACRO EXPECT_BYTE at, value
	LD	A,(at)
	CP	value
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
	LD	(CAP_COUNT),A
	LD	HL,0
	LD	(RX_QLEN),HL
	LD	(RX_QLEN2),HL

	CASE	1			; INIT: the DLL learns its own window
	ENTRY	UNET_FN_INIT
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL

	; Stand in for a completed NETINIT: the overlay is loaded (its blob is
	; already at 0x0000 here) and the driver published an address and a
	; station MAC. Everything else the passive-open path reads it derives
	; from the frame itself.
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

	; GENERATE_TUPLE asks DSS for the seconds counter; there is no DSS
	; here, and the value only seeds an ISN. NETDRV.SEND_FRAME would talk
	; to the card; the stub captures the frame instead and reports success.
	LD	A,0xAF			; XOR A
	LD	(A_SECONDS),A
	LD	A,0xC9			; RET
	LD	(A_SECONDS+1),A
	LD	A,0xC3			; JP CAPTURE_FRAME
	LD	(A_SEND_FRAME),A
	LD	HL,CAPTURE_FRAME
	LD	(A_SEND_FRAME+1),HL
	; The receive half of the card, for the cases that call RECV rather
	; than PROCESS_FRAME directly: the wait loop polls RX_PENDING and then
	; READ_FRAME, and both are the DLL build's plain NETDRV entry points.
	LD	A,0xC3
	LD	(A_RX_PENDING),A
	LD	HL,RX_PENDING_STUB
	LD	(A_RX_PENDING+1),HL
	LD	A,0xC3
	LD	(A_READ_FRAME),A
	LD	HL,READ_FRAME_STUB
	LD	(A_READ_FRAME+1),HL
	; NETTIME.READ_WALL is the third and last routine on this path that
	; needs a machine: it asks DSS for the time of day with its own RST,
	; not through the S9APP.SECONDS patched above, and NETTIME.START calls
	; it on every wait. Frozen at zero the coarse wall watchdog can never
	; fire, which leaves the monotonic quantum count as the only deadline
	; -- the right thing for a vector.
	LD	A,0x21			; LD HL,0
	LD	(A_READ_WALL),A
	LD	HL,0
	LD	(A_READ_WALL+1),HL
	LD	A,0xC9			; RET
	LD	(A_READ_WALL+3),A
	; TCPX.CHECK_CANCEL asks DSS for a keystroke on every pass of the wait
	; loop, with no guard to switch it off. Answer "no key pressed".
	LD	A,0xAF			; XOR A
	LD	(A_CHECK_CANCEL),A
	LD	A,0xC9			; RET
	LD	(A_CHECK_CANCEL+1),A

	CASE	2			; LISTEN arms channel 0 on port 9000
	XOR	A
	LD	DE,LISTEN_PORT
	ENTRY	UNET_FN_LISTEN
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_LISTEN
	; The port the caller asked for, not whatever the helpers left in HL.
	EXPECT_BYTE A_CTX0 + CTX_LOCAL_PORT, LOW LISTEN_PORT
	EXPECT_BYTE A_CTX0 + CTX_LOCAL_PORT + 1, HIGH LISTEN_PORT

	CASE	3			; a SYN for some other port is not ours
	LD	HL,SYN_FRAME
	LD	DE,A_RX_BUF
	LD	BC,SYN_FRAME_LEN
	LDIR
	; Retarget it at port 9001 and keep the frame otherwise perfect: the
	; destination port rises by one, so the one's-complement checksum
	; falls by one. A frame rejected for a bad checksum would prove
	; nothing about the port test.
	LD	A,LOW (LISTEN_PORT+1)
	LD	(A_RX_BUF+37),A
	LD	A,(A_RX_BUF+50)
	LD	H,A
	LD	A,(A_RX_BUF+51)
	LD	L,A
	DEC	HL
	LD	A,H
	LD	(A_RX_BUF+50),A
	LD	A,L
	LD	(A_RX_BUF+51),A
	LD	HL,SYN_FRAME_LEN
	LD	(A_FRAME_LEN),HL
	CALL	A_PROCESS_FRAME
	JP	C,FAIL
	EXPECT_BYTE CAP_COUNT, 0
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_LISTEN

	CASE	4			; a SYN for the bound port is answered
	LD	HL,SYN_FRAME
	LD	DE,A_RX_BUF
	LD	BC,SYN_FRAME_LEN
	LDIR
	LD	HL,SYN_FRAME_LEN
	LD	(A_FRAME_LEN),HL
	CALL	A_PROCESS_FRAME
	JP	C,FAIL
	EXPECT_BYTE CAP_COUNT, 1

	CASE	5			; ...as a SYN|ACK of the expected shape
	LD	HL,(CAP_LEN)
	LD	DE,SYNACK_LEN
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	EXPECT_MEM CAP_BUF, PEER_MAC, 6		; back to the peer that asked
	EXPECT_MEM CAP_BUF+6, STATION_MAC, 6
	EXPECT_BYTE CAP_BUF+12, 0x08
	EXPECT_BYTE CAP_BUF+13, 0x00
	EXPECT_BYTE CAP_BUF+23, 6		; IPv4 protocol TCP
	EXPECT_MEM CAP_BUF+26, LOCAL_IP, 4
	EXPECT_MEM CAP_BUF+30, PEER_IP, 4
	EXPECT_BYTE CAP_BUF+34, HIGH LISTEN_PORT
	EXPECT_BYTE CAP_BUF+35, LOW LISTEN_PORT
	EXPECT_BYTE CAP_BUF+36, HIGH PEER_PORT
	EXPECT_BYTE CAP_BUF+37, LOW PEER_PORT
	EXPECT_BYTE CAP_BUF+47, TCP_FLAG_SYN|TCP_FLAG_ACK
	EXPECT_MEM CAP_BUF+42, EXPECT_ACK, 4	; the peer's ISN + 1

	CASE	6			; the IPv4 header checksum is right
	LD	HL,0
	LD	IX,CAP_BUF+14
	LD	BC,20
	CALL	CKSUM_ADD
	LD	A,H
	AND	L
	CP	0xFF
	JP	NZ,FAIL

	CASE	7			; and so is the TCP checksum. This is the
					; one a peer silently drops us for: a SYN|
					; ACK with a bad checksum looks exactly
					; like no answer at all from the client's
					; side of the wire.
	LD	HL,CAP_BUF+26		; source IP, then destination IP
	LD	DE,PSEUDO
	LD	BC,8
	LDIR
	XOR	A
	LD	(PSEUDO+8),A
	LD	A,6
	LD	(PSEUDO+9),A
	LD	A,0
	LD	(PSEUDO+10),A
	LD	A,SYNACK_LEN-34
	LD	(PSEUDO+11),A
	LD	HL,0
	LD	IX,PSEUDO
	LD	BC,12
	CALL	CKSUM_ADD
	LD	IX,CAP_BUF+34
	LD	BC,SYNACK_LEN-34
	CALL	CKSUM_ADD
	LD	A,H
	AND	L
	CP	0xFF
	JP	NZ,FAIL

	CASE	8			; the listener is half-open, not accepted
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_SYN_RECEIVED
	EXPECT_MEM A_CTX0 + CTX_RCV_NXT, EXPECT_ACK, 4
	EXPECT_BYTE A_CTX0 + CTX_REMOTE_PORT, LOW PEER_PORT
	EXPECT_BYTE A_CTX0 + CTX_REMOTE_PORT + 1, HIGH PEER_PORT
	EXPECT_MEM A_CTX0 + CTX_REMOTE_IP, PEER_IP, 4
	EXPECT_MEM A_CTX0 + CTX_REMOTE_MAC, PEER_MAC, 6

	CASE	9			; the handshake's closing ACK, delivered the
					; way the wire delivers it: RECV drives the
					; wait loop, and ACCEPT_POLL deliberately
					; clears any stale SYN_ACK event on entry,
					; so the segment has to arrive DURING the
					; call for the accept to happen at all.
	CALL	BUILD_ACK
	LD	HL,ACK_FRAME
	LD	(RX_QSRC),HL
	LD	HL,ACK_LEN
	LD	(RX_QLEN),HL
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,20
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_ESTABLISHED
	EXPECT_BYTE A_CH_STATE, 1		; an ordinary connected channel
	EXPECT_BYTE A_LISTEN_ACC, 1		; flagged as accepted, for STATUS

	CASE	10			; unet.inc function 6: "-> A, DE=bytes sent".
					; TCPX.SEND returns that count in DE and
					; CLOBBERS BC (its own header) -- the
					; opposite of TCPX.RECV, which returns BC.
					; A shim that reads BC hands the caller a
					; garbage count, and a consumer that
					; advances its own buffer by it walks off
					; the end: the NEXT call arrives with a wild
					; length and is rejected as NERR_PARAM, so
					; the damage surfaces one call away from its
					; cause. BINK.EXE saw 33 for a 19-byte send
					; on hardware before this case existed.
	CALL	BUILD_DATA_ACK
	XOR	A
	LD	DE,SEND_PAYLOAD
	LD	IX,SEND_LEN
	ENTRY	UNET_FN_SEND
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	LD	HL,SEND_LEN
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL

	CASE	11			; the peer reads its reply and hangs up
	CALL	BUILD_FIN
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,50
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	CP	NERR_CLOSED
	JP	NZ,FAIL

	CASE	12			; unet.inc, function 18: "CLOSE (or a peer
					; close) of the accepted connection re-arms
					; LISTEN on the same port". Reporting
					; NERR_CLOSED and leaving the channel dead
					; is what stranded peer #2 on hardware.
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_LISTEN
	EXPECT_BYTE A_CTX0 + CTX_LOCAL_PORT, LOW LISTEN_PORT
	EXPECT_BYTE A_CTX0 + CTX_LOCAL_PORT + 1, HIGH LISTEN_PORT
	EXPECT_BYTE A_CH_STATE, 3
	EXPECT_BYTE A_LISTEN_ACC, 0

	CASE	13			; and the re-armed listener answers the
					; next SYN, which is the symptom itself
	XOR	A
	LD	(CAP_COUNT),A
	LD	HL,SYN_FRAME
	LD	DE,A_RX_BUF
	LD	BC,SYN_FRAME_LEN
	LDIR
	LD	HL,SYN_FRAME_LEN
	LD	(A_FRAME_LEN),HL
	CALL	A_PROCESS_FRAME
	JP	C,FAIL
	EXPECT_BYTE CAP_COUNT, 1
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_SYN_RECEIVED

	CASE	14			; finish this second accept, so the cases
					; below have an established connection again
	CALL	BUILD_ACK
	LD	HL,ACK_FRAME
	LD	(RX_QSRC),HL
	LD	HL,ACK_LEN
	LD	(RX_QLEN),HL
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,20
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_ESTABLISHED

	CASE	15			; unet.inc reads IY=0 as "poll, do not block":
					; an idle link answers NERR_OK with DE=0. The
					; timebase under every wait here takes
					; BC=1..65535 and rejects 0 with
					; NETDRV_ERR_PARAMETER, which MAP_RECV_FAIL
					; turns into NERR_PARAM -- so an unclamped zero
					; failed every drain-before-send poll, which is
					; the idiom unet.inc itself prescribes for SEND
					; and the one BINK.EXE uses. Case 17's IY=0
					; cannot catch it: a channel whose FIN already
					; arrived answers from the context and never
					; reaches the timebase at all.
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,0
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	OR	A
	JP	NZ,FAIL
	LD	A,D
	OR	E
	JP	NZ,FAIL
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_ESTABLISHED

	CASE	16			; an ORDINARY channel must SURVIVE its peer's
					; FIN. unet.inc has RECV merely report the
					; close, TCPX.SEND deliberately accepts
					; CLOSE_WAIT, and half-close is how a protocol
					; finishes its own side. Releasing the channel
					; here -- which the LISTEN re-arm above must do
					; -- zeroed its state instead, and that is how a
					; binkp mailer lost the M_EOB it still owed
					; after the boss hung up first.
	XOR	A
	LD	(A_LISTEN_ACC),A	; this one did not come from LISTEN
	CALL	BUILD_FIN
	LD	HL,0
	LD	(RX_QLEN2),HL		; only the peer's FIN: we send none back
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,50
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	CP	NERR_CLOSED
	JP	NZ,FAIL
	EXPECT_BYTE A_CH_STATE, 1		; still the caller's own channel
	EXPECT_BYTE A_CTX0 + CTX_STATE, TCP_STATE_CLOSE_WAIT

	CASE	17			; and the answer stays NERR_CLOSED however
					; often it is polled -- a consumer that drains
					; in a loop must not see it turn into
					; NERR_STATE half way through
	XOR	A
	LD	DE,RECV_BUF
	LD	IX,RECV_BUF_SIZE
	LD	IY,0
	ENTRY	UNET_FN_RECV
	JP	C,FAIL
	CP	NERR_CLOSED
	JP	NZ,FAIL

	JP	PASS

; ------------------------------------------------------
; CAPTURE_FRAME stands in for NETDRV.SEND_FRAME: In HL=frame, BC=length.
; Out: CF=0/A=0, exactly as a successful transmission reports.
; ------------------------------------------------------
CAPTURE_FRAME
	LD	(CAP_LEN),BC
	LD	DE,CAP_BUF
	LDIR
	LD	A,(CAP_COUNT)
	INC	A
	LD	(CAP_COUNT),A
	XOR	A
	RET

; ------------------------------------------------------
; RX_PENDING_STUB stands in for NETDRV.RX_PENDING: A=0 when the wire is
; quiet, non-zero when a frame is queued. CF=0 (no hardware error).
; ------------------------------------------------------
RX_PENDING_STUB
	LD	A,(RX_QLEN)
	LD	HL,RX_QLEN+1
	OR	(HL)
	RET	Z
	LD	A,1
	OR	A
	RET

; ------------------------------------------------------
; READ_FRAME_STUB stands in for NETDRV.READ_FRAME: In HL=buffer, BC=capacity.
; Out BC=length, CF=0. Delivers the queued frame and promotes the one behind
; it, so a case can stage a peer's FIN and the ACK of our answering FIN in
; one go -- without the second frame CLOSE would sit out its full
; FIN_TIMEOUT_MS, which is five seconds of emulated time.
; ------------------------------------------------------
READ_FRAME_STUB
	EX	DE,HL			; DE = caller's buffer
	LD	HL,(RX_QSRC)
	LD	BC,(RX_QLEN)
	PUSH	BC
	LDIR
	LD	HL,(RX_QSRC2)
	LD	(RX_QSRC),HL
	LD	HL,(RX_QLEN2)
	LD	(RX_QLEN),HL
	LD	HL,0
	LD	(RX_QLEN2),HL
	POP	BC
	XOR	A			; CF=0
	RET

; ------------------------------------------------------
; BUILD_FIN stages what a peer that has read its reply actually sends: the
; FIN|ACK on the connection ACK_FRAME opened, and behind it the
; acknowledgement of the FIN we answer with. Sequence and acknowledgement
; numbers are derived from ACK_FRAME, so our own random ISN stays honest.
; ------------------------------------------------------
BUILD_FIN
	LD	HL,ACK_FRAME
	LD	DE,FIN_FRAME
	LD	BC,ACK_LEN
	LDIR
	LD	A,(FIN_FRAME+47)
	OR	TCP_FLAG_FIN
	LD	(FIN_FRAME+47),A
	LD	IY,FIN_FRAME
	CALL	FIX_TCP_CKSUM
	LD	HL,FIN_FRAME
	LD	DE,FINACK_FRAME
	LD	BC,ACK_LEN
	LDIR
	LD	A,TCP_FLAG_ACK
	LD	(FINACK_FRAME+47),A
	LD	HL,FINACK_FRAME+41
	CALL	INC32_AT		; past the peer's own FIN
	LD	HL,FINACK_FRAME+45
	CALL	INC32_AT		; and past ours
	LD	IY,FINACK_FRAME
	CALL	FIX_TCP_CKSUM
	LD	HL,FIN_FRAME
	LD	(RX_QSRC),HL
	LD	HL,FINACK_FRAME
	LD	(RX_QSRC2),HL
	LD	HL,ACK_LEN
	LD	(RX_QLEN),HL
	LD	(RX_QLEN2),HL
	RET

; ------------------------------------------------------
; BUILD_DATA_ACK stages the peer's acknowledgement of the SEND_LEN payload
; bytes the SEND case is about to transmit: the handshake ACK with its
; acknowledgement number advanced past them, and nothing else moved (the peer
; sends no data of its own here). It has to be queued BEFORE the SEND,
; because SEND blocks in its own wait loop until this frame is read.
; ------------------------------------------------------
BUILD_DATA_ACK
	LD	HL,ACK_FRAME
	LD	DE,DATA_ACK_FRAME
	LD	BC,ACK_LEN
	LDIR
	LD	B,SEND_LEN
.bump
	PUSH	BC
	LD	HL,DATA_ACK_FRAME+45
	CALL	INC32_AT
	POP	BC
	DJNZ	.bump
	LD	IY,DATA_ACK_FRAME
	CALL	FIX_TCP_CKSUM
	LD	HL,DATA_ACK_FRAME
	LD	(RX_QSRC),HL
	LD	HL,ACK_LEN
	LD	(RX_QLEN),HL
	RET

; The SEND case's payload. It lives in the vectors' own image, i.e. in
; window 2 with the DLL in window 1 -- the same split a normal DSS EXE has.
SEND_PAYLOAD	DB "bink"

; INC32_AT: increment the big-endian 32-bit field whose LAST byte is at HL.
INC32_AT
	LD	B,4
.loop
	INC	(HL)
	LD	A,(HL)
	OR	A
	RET	NZ
	DEC	HL
	DJNZ	.loop
	RET

; ------------------------------------------------------
; FIX_TCP_CKSUM: In IY = a 54-byte optionless IPv4/TCP frame. Recomputes its
; TCP checksum in place (the IPv4 header is never touched by these edits, so
; its own checksum still stands). Clobbers AF/BC/DE/HL/IX.
; ------------------------------------------------------
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
	XOR	A
	LD	(PSEUDO+10),A
	LD	A,ACK_LEN-34
	LD	(PSEUDO+11),A
	LD	HL,0
	LD	IX,PSEUDO
	LD	BC,12
	CALL	CKSUM_ADD
	PUSH	IY
	POP	IX
	LD	BC,34
	ADD	IX,BC
	LD	BC,ACK_LEN-34
	CALL	CKSUM_ADD
	LD	A,H
	CPL
	LD	(IY+50),A
	LD	A,L
	CPL
	LD	(IY+51),A
	RET

; ------------------------------------------------------
; BUILD_ACK writes the peer's final handshake ACK into ACK_FRAME. Our own
; ISN is generated from DSS seconds and the refresh register, so the
; acknowledgement number can only be read back out of the SYN|ACK we just
; captured -- which is also what makes this a real test of that field.
; ------------------------------------------------------
BUILD_ACK
	LD	HL,ACK_TEMPLATE
	LD	DE,ACK_FRAME
	LD	BC,ACK_LEN
	LDIR
	LD	HL,CAP_BUF+38		; our ISN, from the SYN|ACK's sequence
	LD	DE,ACK_FRAME+42		; the peer acknowledges ISN + 1
	LD	BC,4
	LDIR
	LD	HL,ACK_FRAME+45
	CALL	INC32_AT
	LD	IY,ACK_FRAME
	JP	FIX_TCP_CKSUM

; ------------------------------------------------------
; CKSUM_ADD: fold BC bytes at IX into the one's-complement sum in HL, big
; endian, end-around carry. BC must be even. Out: HL=sum, IX past the last
; byte. Clobbers AF/BC/DE. A complete header sums to 0xFFFF.
; ------------------------------------------------------
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

STATION_MAC	DB 0x02,0x60,0x8C,0x11,0x22,0x33
PEER_MAC	DB 0x02,0xAA,0xBB,0xCC,0xDD,0xEE
LOCAL_IP	DB 192,168,1,148
PEER_IP		DB 192,168,1,36
EXPECT_ACK	DB 0x11,0x22,0x33,0x45	; the peer's ISN 0x11223344, plus the SYN

; A macOS-shaped SYN to 192.168.1.148:9000 from 192.168.1.36:50000, sequence
; 0x11223344, 20 bytes of options (MSS 1460, window scale, timestamps), both
; checksums valid. Generated, not hand-computed.
SYN_FRAME
	DB	0x02,0x60,0x8C,0x11,0x22,0x33,0x02,0xAA,0xBB,0xCC,0xDD,0xEE
	DB	0x08,0x00,0x45,0x00,0x00,0x3C,0xBE,0xEF,0x40,0x00,0x40,0x06
	DB	0xF7,0xC3,0xC0,0xA8,0x01,0x24,0xC0,0xA8,0x01,0x94,0xC3,0x50
	DB	0x23,0x28,0x11,0x22,0x33,0x44,0x00,0x00,0x00,0x00,0xA0,0x02
	DB	0xFF,0xFF,0x98,0x14,0x00,0x00,0x02,0x04,0x05,0xB4,0x01,0x03
	DB	0x03,0x06,0x01,0x01,0x08,0x0A,0x01,0x02,0x03,0x04,0x00,0x00
	DB	0x00,0x00
SYN_FRAME_LEN	EQU $ - SYN_FRAME

; The handshake's closing ACK: no options, sequence 0x11223345. BUILD_ACK
; fills in the acknowledgement number and the checksum from the captured
; SYN|ACK, so the two zero words below are placeholders.
ACK_TEMPLATE
	DB	0x02,0x60,0x8C,0x11,0x22,0x33,0x02,0xAA,0xBB,0xCC,0xDD,0xEE
	DB	0x08,0x00,0x45,0x00,0x00,0x28,0xBE,0xF0,0x40,0x00,0x40,0x06
	DB	0xF7,0xD6,0xC0,0xA8,0x01,0x24,0xC0,0xA8,0x01,0x94,0xC3,0x50
	DB	0x23,0x28,0x11,0x22,0x33,0x45,0x00,0x00,0x00,0x00,0x50,0x10
	DB	0xFF,0xFF,0x00,0x00,0x00,0x00
ACK_LEN		EQU $ - ACK_TEMPLATE

	SAVEBIN "listen_vectors.bin",0,0x10000
