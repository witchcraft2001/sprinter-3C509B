; DLSPEED.EXE - honest HTTP/1.0 download throughput measurement over the
; 3C509B backend. Development/measurement tool only: IMG, never the ZIP.
; SPDX-License-Identifier: BSD-3-Clause
;
; The body is discarded as it arrives -- no disk write, no file handle -- so
; the measured rate is the network path alone, not disk I/O. Timing starts
; and stops on saved RTC snapshots taken immediately around the GET/response
; exchange, aligned to a whole-second edge first so a sub-second start error
; cannot skew a short sample. No progress is printed while timed: console
; output would compete with the transfer for the same 21 MHz Z80.

EXE_VERSION	EQU 1
; Same standard-layout arrangement as WGET: PAGE_BASE 8000h, own WIN2, deep
; single-channel receive window (both keyed off STAGE12_LAYOUT). DLSPEED
; never defines STAGE13_LAYOUT, so it reuses WGET's own W12_* state fields
; from memory.inc verbatim -- the two EXEs never coexist in memory.
	DEFINE RUNTIME_BASE 0xB000
	DEFINE STAGE9_LAYOUT
	DEFINE STAGE10_PAGE_LAYOUT
	DEFINE STAGE10_DNS
	DEFINE STAGE11_LAYOUT
	DEFINE STAGE12_LAYOUT
	; Image headroom to spare, so take the unrolled FIFO burst (el3_io.asm).
	DEFINE FAST_DATAPATH
	; Round-2 throughput: driver primitives must never be called from inside
	; PROCESS_FRAME/HANDLE_SEGMENT's own call chain (tcp_transport.asm), so
	; the ACK a segment earns is deferred to .WAIT_LOOP instead of sent
	; in-line. FTP does not define this and keeps the byte-identical old
	; behavior -- its image has no room to spare for this yet.
	DEFINE TCPX_DIRECT_RX
	; One ISA-window session per receive step (el3_io.asm's RX_BEGIN/
	; RX_PAYLOAD/RX_DROP) instead of the several RX_PENDING/READ_FRAME used
	; apart. Additive only: RX_PENDING/READ_FRAME themselves are untouched,
	; so ARP/DNS/other non-TCP traffic on this same EXE is unaffected.
	DEFINE EL3_SESSION_RX

	DEVICE NOSLOT64K
	INCLUDE "version.inc"
	INCLUDE "dss.inc"
	INCLUDE "macro.inc"
	INCLUDE "memory.inc"
	INCLUDE "el3.inc"
	INCLUDE "netdrv.inc"
	INCLUDE "netcfg.inc"
	INCLUDE "ip_icmp.inc"
	INCLUDE "udp_tftp.inc"
	INCLUDE "dns_ntp.inc"
	INCLUDE "tcp.inc"

	MODULE MAIN

HTTP_IDLE_MS	EQU 15000
RTC_ALIGN_TIMEOUT_MS EQU 2500

	ORG 0x4080
	DB "EXE",EXE_VERSION
	DW 0x0080,0,0,0,0,0
	DW START,START,S10_BOOTSTRAP_STACK
	DS 106,0

	ORG 0x4100
START
	LD	SP,S10_BOOTSTRAP_STACK
	CALL	@S11APP.SAVE_COMMAND
	CALL	@S11APP.ALLOCATE_FRESH
	JP	C,BOOT_FAIL
	LD	SP,S10_RUNTIME_STACK_TOP
	LD	(CMDLINE_SOURCE),IX
	LD	HL,MSG_BANNER
	CALL	@CONSOLE.LINE
	CALL	CLEAR_STATE
	CALL	@ARP.CLEAR_CACHE
	CALL	PARSE_DLSPEED_CLI
	JR	NC,.ARGS_OK
	CP	EL3_CLI_HELP
	JP	NZ,USAGE_FAIL
	LD	HL,MSG_HELP
	CALL	@CONSOLE.STRING
	JP	SUCCESS
.ARGS_OK
	LD	HL,W12_URL
	CALL	PARSE_URL
	JP	C,USAGE_FAIL
	CALL	@S9APP.LOAD_ACTIVE_CONFIG
	JP	C,CONFIG_FAIL
	CALL	@S9APP.INIT_DRIVER
	JP	C,HARDWARE_FAIL

	LD	HL,W12_HOST
	CALL	@DNSX.RESOLVE_OR_LITERAL
	JP	C,RESOLVE_FAIL
	LD	HL,MSG_RESOLVED
	CALL	@CONSOLE.STRING
	LD	HL,W12_HOST
	CALL	@CONSOLE.STRING
	LD	HL,MSG_TO
	CALL	@CONSOLE.STRING
	LD	HL,NET_TARGET_IP
	CALL	PRINT_IPV4
	LD	HL,MSG_PORT
	CALL	@CONSOLE.STRING
	LD	HL,(W12_PORT)
	CALL	@CONSOLE.DEC16
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING

	CALL	@TCPX.RESET
	XOR	A
	LD	HL,NET_TARGET_IP
	LD	BC,(W12_PORT)
	CALL	@TCPX.OPEN
	JP	C,TCP_OPEN_FAIL
	LD	HL,MSG_CONNECTED
	CALL	@CONSOLE.LINE

	LD	HL,MSG_WAIT_EDGE
	CALL	@CONSOLE.LINE
	CALL	WAIT_RTC_EDGE
	JP	C,RTC_FAIL
	CALL	TIME_START

	CALL	BUILD_GET
	XOR	A
	LD	HL,S11_APP_BUFFER
	LD	BC,(W12_REQUEST_LENGTH)
	CALL	@TCPX.SEND
	JP	C,TCP_SEND_FAIL
	CALL	RESET_HTTP_STATE

; One RECV per bufferful instead of one per segment: with direct delivery
; (tcp_transport.asm's FAST_RECEIVE) the transport writes segments straight
; into this buffer and only returns once it can no longer take a whole MSS, so
; the DSS clock read and key scan RECV makes are paid once per eleven segments
; here rather than once each. STAGE9_FILE_BUFFER is otherwise unused -- DLSPEED
; discards the body, and PROCESS_CHUNK parses out of whatever buffer it is
; handed.
.RX_LOOP
	XOR	A
	LD	HL,STAGE9_FILE_BUFFER
	LD	BC,STAGE9_FILE_CAPACITY
	LD	DE,HTTP_IDLE_MS
	CALL	@TCPX.RECV
	JR	C,.RX_END_OR_FAIL
	LD	HL,STAGE9_FILE_BUFFER
	CALL	PROCESS_CHUNK
	LD	A,(W12_HOP_DONE)
	OR	A
	JP	NZ,HTTP_FAIL
	CALL	BODY_COMPLETE
	JR	C,.RX_LOOP
	; The declared Content-Length has arrived, so the response is over by
	; its own framing: stop the clock here instead of waiting for a FIN.
	; A keep-alive server (HTTP/1.1 is the default for Python's own
	; http.server, and DLSPEED's "Connection: close" is only a request) is
	; entitled to hold the socket open indefinitely -- waiting for its FIN
	; would burn HTTP_IDLE_MS and then report a bogus 0x1E on a transfer
	; that actually completed byte-exact. CLOSE, not ABORT: the peer gets
	; an orderly FIN rather than an RST in the middle of its own keep-alive
	; bookkeeping.
	CALL	CAPTURE_STOP
	XOR	A
	CALL	@TCPX.CLOSE
	JR	.RESPONSE_DONE
.RX_END_OR_FAIL
	CP	TCP_ERR_CLOSED
	JR	Z,.PEER_CLOSED
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	JP	TCP_RECV_FAIL
.PEER_CLOSED
	CALL	CAPTURE_STOP
	XOR	A
	CALL	@TCPX.CLOSE
	; A close-delimited response (no Content-Length) ends exactly here, and
	; only here. One that declared a length and stopped short of it is a
	; truncated transfer, not a measurement: report it instead of printing
	; a rate for a partial body.
	LD	A,(W12_CONTENT_KNOWN)
	OR	A
	JR	Z,.RESPONSE_DONE
	CALL	BODY_COMPLETE
	JP	C,TCP_RECV_FAIL_PROTOCOL
.RESPONSE_DONE
	LD	A,(W12_STATUS_SEEN)
	OR	A
	JP	Z,TCP_RECV_FAIL_PROTOCOL
	LD	A,(W12_HTTP_STATE)
	CP	4
	JP	NZ,TCP_RECV_FAIL_PROTOCOL
	LD	A,(W12_HOP_DONE)
	OR	A
	JP	NZ,HTTP_FAIL

	LD	HL,MSG_RECEIVED
	CALL	@CONSOLE.STRING
	LD	HL,(W12_BODY_RECEIVED)
	LD	DE,(W12_BODY_RECEIVED+2)
	CALL	PRINT_DEC32
	LD	HL,MSG_BYTES
	CALL	@CONSOLE.LINE
	CALL	TIME_REPORT
	JP	C,SAMPLE_TOO_SHORT
	JP	SUCCESS

CLEAR_STATE
	LD	HL,W12_STATE_BASE
	LD	B,0x40
	XOR	A
.CLEAR
	LD	(HL),A
	INC	HL
	DJNZ	.CLEAR
	RET

RESET_HTTP_STATE
	XOR	A
	LD	HL,W12_HTTP_STATE
	LD	B,6
.CLEAR_HTTP
	LD	(HL),A
	INC	HL
	DJNZ	.CLEAR_HTTP
	LD	(W12_STATUS_SEEN),A
	LD	(W12_HOP_DONE),A
	RET

; PARSE_DLSPEED_CLI: exactly one positional (the URL), or -h/-?/--help.
PARSE_DLSPEED_CLI
	CALL	@S9CLI.READER_INIT
	CALL	@S9CLI.NEXT_TOKEN
	JR	C,.BAD
	LD	A,(CLI_TOKEN_LEN)
	CP	2
	JR	NZ,.URL
	LD	A,(HL)
	CP	'-'
	JR	Z,.OPT
	CP	'/'
	JR	NZ,.URL
.OPT
	INC	HL
	LD	A,(HL)
	CALL	@S9CLI.UPPER
	CP	'H'
	JR	Z,.HELP
	CP	'?'
	JR	Z,.HELP
	JR	.BAD
.URL
	LD	DE,W12_URL
	LD	C,255
	CALL	@S9CLI.COPY_TOKEN
	JR	C,.BAD
	CALL	@S9CLI.NEXT_TOKEN
	JR	NC,.BAD			; exactly one token
	XOR	A
	RET
.HELP
	LD	A,EL3_CLI_HELP
	SCF
	RET
.BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

; WAIT_RTC_EDGE blocks until DSS_SYSTIME's second field changes, bounded so a
; stopped or unavailable RTC cannot hang the measurement. The countdown is
; kept in memory, not HL: @S9APP.SECONDS's own RST DSS call returns HL as
; part of DSS_SYSTIME's result and does not preserve it, so a live-in-HL
; countdown here would be silently overwritten every iteration and never
; reach zero -- exactly the bounded-timeout guarantee this loop exists for.
WAIT_RTC_EDGE
	CALL	@S9APP.SECONDS
	LD	(W12_LAST_ERROR),A
	LD	HL,RTC_ALIGN_TIMEOUT_MS
	LD	(W12_WORK32),HL
.LOOP
	CALL	@S9APP.WAIT_TICK
	CALL	@S9APP.SECONDS
	LD	B,A
	LD	A,(W12_LAST_ERROR)
	CP	B
	JR	NZ,.EDGE
	LD	HL,(W12_WORK32)
	DEC	HL
	LD	(W12_WORK32),HL
	LD	A,H
	OR	L
	JR	NZ,.LOOP
	SCF
	RET
.EDGE
	OR	A
	RET

; Assemble GET, Host and Connection: close headers in the application work
; area, same layout as WGET's BUILD_GET but with no Range support.
BUILD_GET
	LD	DE,S11_APP_BUFFER
	LD	HL,LIT_GET
	CALL	COPY_Z_EXCEPT_NUL
	LD	HL,W12_PATH
	CALL	COPY_Z_EXCEPT_NUL
	LD	HL,LIT_HTTP_HOST
	CALL	COPY_Z_EXCEPT_NUL
	LD	HL,W12_HOST
	CALL	COPY_Z_EXCEPT_NUL
	LD	HL,LIT_REST
	CALL	COPY_Z_EXCEPT_NUL
	LD	HL,S11_APP_BUFFER
	EX	DE,HL
	OR	A
	SBC	HL,DE
	LD	(W12_REQUEST_LENGTH),HL
	RET

COPY_Z_EXCEPT_NUL
	LD	A,(HL)
	OR	A
	RET	Z
	LD	(DE),A
	INC	HL
	INC	DE
	JR	COPY_Z_EXCEPT_NUL

; Feed arbitrary TCP segmentation through a line capture and CRLFCRLF state
; machine identical to WGET's, except the body is counted and discarded
; instead of buffered for a disk write.
PROCESS_CHUNK
	LD	A,B
	OR	C
	RET	Z
	LD	A,(W12_HTTP_STATE)
	CP	4
	JR	Z,.BODY
.HEADER_LOOP
	LD	A,(HL)
	PUSH	HL,BC
	CALL	CAPTURE_HEADER_BYTE
	POP	BC,HL
	LD	A,(HL)
	CALL	HEADER_TRANSITION
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	RET	Z
	LD	A,(W12_HTTP_STATE)
	CP	4
	JR	NZ,.HEADER_LOOP
.BODY
	LD	A,(W12_HOP_DONE)
	OR	A
	RET	NZ
	LD	HL,(W12_BODY_RECEIVED)
	ADD	HL,BC
	LD	(W12_BODY_RECEIVED),HL
	RET	NC
	LD	HL,(W12_BODY_RECEIVED+2)
	INC	HL
	LD	(W12_BODY_RECEIVED+2),HL
	RET

; BODY_COMPLETE: CF=1 "keep receiving", CF=0 "the body is complete".
; Complete means: the headers are over (state 4), a Content-Length was
; declared, and at least that many body bytes have been counted. Without a
; declared length the only legal end-of-body marker is the peer's FIN, so
; this always answers "keep receiving" and .PEER_CLOSED does the deciding.
; Trashes A, DE, HL.
BODY_COMPLETE
	LD	A,(W12_HTTP_STATE)
	CP	4
	JR	NZ,.MORE
	LD	A,(W12_CONTENT_KNOWN)
	OR	A
	JR	Z,.MORE
	; 32-bit received - declared: CF=1 (borrow) means still short. A body
	; longer than declared (a broken server) also ends the transfer here
	; rather than hanging; W12_BODY_RECEIVED then reports what really
	; arrived, which is what a measurement tool should say.
	LD	HL,(W12_BODY_RECEIVED)
	LD	DE,(W12_CONTENT_LENGTH)
	OR	A
	SBC	HL,DE
	LD	HL,(W12_BODY_RECEIVED+2)
	LD	DE,(W12_CONTENT_LENGTH+2)
	SBC	HL,DE
	RET
.MORE
	SCF
	RET

; CHECK_CONTENT_LENGTH: on a captured header line reading "Content-Length:"
; (case-insensitive, per RFC 7230 field names), parse the 32-bit decimal
; value into W12_CONTENT_LENGTH and raise W12_CONTENT_KNOWN. Anything else,
; including a malformed or empty value, leaves both untouched -- the
; response then falls back to close-delimited framing rather than being
; rejected, since HTTP/1.0 allows exactly that. Trashes A, BC, DE, HL.
CHECK_CONTENT_LENGTH
	LD	HL,W12_HEADER_LINE
	LD	DE,LIT_CONTENT_LENGTH
.PREFIX
	LD	A,(DE)
	OR	A
	JR	Z,.VALUE
	LD	C,A
	LD	A,(HL)
	CALL	TOLOWER
	CP	C
	RET	NZ
	INC	HL
	INC	DE
	JR	.PREFIX
.VALUE
	LD	A,(HL)
	CP	' '
	JR	Z,.SKIP
	CP	9
	JR	NZ,.DIGITS
.SKIP
	INC	HL
	JR	.VALUE
.DIGITS
	LD	DE,0
	LD	(W12_WORK32),DE
	LD	(W12_WORK32+2),DE
	LD	B,0
.NEXT
	LD	A,(HL)
	SUB	'0'
	JR	C,.END
	CP	10
	JR	NC,.END
	INC	B
	LD	C,A
	PUSH	HL
	CALL	MUL_WORK32_10
	LD	A,(W12_WORK32)
	ADD	A,C
	LD	(W12_WORK32),A
	JR	NC,.NO_CARRY
	LD	HL,W12_WORK32+1
	INC	(HL)
	JR	NZ,.NO_CARRY
	INC	HL
	INC	(HL)
	JR	NZ,.NO_CARRY
	INC	HL
	INC	(HL)
.NO_CARRY
	POP	HL
	INC	HL
	JR	.NEXT
.END
	LD	A,B
	OR	A
	RET	Z			; no digits at all: not a usable length
	LD	HL,(W12_WORK32)
	LD	(W12_CONTENT_LENGTH),HL
	LD	HL,(W12_WORK32+2)
	LD	(W12_CONTENT_LENGTH+2),HL
	LD	A,1
	LD	(W12_CONTENT_KNOWN),A
	RET

; W12_WORK32 *= 10, via (x*2) + (x*8). W12_CONTENT_LENGTH holds the x*2
; addend meanwhile: it is written for real only once the whole value has
; been parsed, so it is free scratch until then (same trick as WGET's).
MUL_WORK32_10
	CALL	SHIFT_WORK32		; 2x, kept as the addend
	LD	HL,(W12_WORK32)
	LD	DE,(W12_WORK32+2)
	LD	(W12_CONTENT_LENGTH),HL
	LD	(W12_CONTENT_LENGTH+2),DE
	CALL	SHIFT_WORK32		; 4x
	CALL	SHIFT_WORK32		; 8x
	LD	HL,(W12_WORK32)
	LD	DE,(W12_CONTENT_LENGTH)
	ADD	HL,DE
	LD	(W12_WORK32),HL
	LD	HL,(W12_WORK32+2)
	LD	DE,(W12_CONTENT_LENGTH+2)
	ADC	HL,DE
	LD	(W12_WORK32+2),HL
	RET

SHIFT_WORK32
	LD	HL,W12_WORK32
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	RET

CAPTURE_HEADER_BYTE
	LD	(W12_LAST_ERROR),A
	CP	10
	RET	Z
	CP	13
	JR	Z,.EOL
	LD	A,(W12_HEADER_LENGTH)
	CP	255
	JR	NC,.OVERFLOW
	LD	E,A
	LD	D,0
	LD	HL,W12_HEADER_LINE
	ADD	HL,DE
	LD	A,(W12_LAST_ERROR)
	LD	(HL),A
	LD	HL,W12_HEADER_LENGTH
	INC	(HL)
	RET
.OVERFLOW
	RET
.EOL
	LD	A,(W12_HEADER_LENGTH)
	LD	E,A
	LD	D,0
	LD	HL,W12_HEADER_LINE
	ADD	HL,DE
	LD	(HL),0
	LD	A,(W12_STATUS_SEEN)
	OR	A
	JR	NZ,.HEADER
	CALL	PARSE_STATUS_LINE
	LD	A,1
	LD	(W12_STATUS_SEEN),A
	JR	.RESET
.HEADER
	CALL	CHECK_CONTENT_LENGTH
.RESET
	XOR	A
	LD	(W12_HEADER_LENGTH),A
	RET
HEADER_TRANSITION
	LD	(W12_LAST_ERROR),A
	LD	A,(W12_HTTP_STATE)
	OR	A
	JR	Z,.S0
	CP	1
	JR	Z,.S1
	CP	2
	JR	Z,.S2
	CP	3
	JR	Z,.S3
	RET
.S0
	LD	A,(W12_LAST_ERROR)
	CP	13
	RET	NZ
	LD	A,1
	JR	.STORE
.S1
	LD	A,(W12_LAST_ERROR)
	CP	10
	LD	A,2
	JR	Z,.STORE
	LD	A,(W12_LAST_ERROR)
	CP	13
	LD	A,1
	JR	Z,.STORE
	XOR	A
	JR	.STORE
.S2
	LD	A,(W12_LAST_ERROR)
	CP	13
	LD	A,3
	JR	Z,.STORE
	XOR	A
	JR	.STORE
.S3
	LD	A,(W12_LAST_ERROR)
	CP	10
	LD	A,4
	JR	Z,.STORE
	LD	A,(W12_LAST_ERROR)
	CP	13
	LD	A,1
	JR	Z,.STORE
	XOR	A
.STORE
	LD	(W12_HTTP_STATE),A
	RET

; PARSE_STATUS_LINE classifies the reply: DLSPEED needs a body to measure,
; so it treats anything but 2xx as fatal -- no redirect following.
PARSE_STATUS_LINE
	LD	HL,W12_HEADER_LINE
.SPACE
	LD	A,(HL)
	OR	A
	JP	Z,.BAD
	CP	' '
	JR	Z,.DIGIT_START
	INC	HL
	JR	.SPACE
.DIGIT_START
	INC	HL
	LD	DE,0
	LD	B,0
.DIGIT
	LD	A,(HL)
	SUB	'0'
	JR	C,.END
	CP	10
	JR	NC,.END
	INC	B
	LD	C,A
	PUSH	HL
	LD	H,D
	LD	L,E
	ADD	HL,HL
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	LD	D,0
	LD	E,C
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	INC	HL
	JR	.DIGIT
.END
	LD	A,B
	OR	A
	JP	Z,.BAD
	LD	(W12_STATUS),DE
	LD	A,D
	OR	A
	JR	Z,.CLASS_LOW
	LD	A,1
	CP	D
	JP	NZ,.BAD
	LD	A,E
	CP	44
	JR	C,.SUCCESS		; 256..299
	JP	.BAD
.CLASS_LOW
	LD	A,E
	CP	200
	JP	C,.BAD
	CP	244			; 200..243
	JR	NC,.BAD
.SUCCESS
	RET
.BAD
	LD	A,1
	LD	(W12_HOP_DONE),A
	LD	HL,MSG_HTTP_ERROR
	CALL	@CONSOLE.STRING
	LD	HL,W12_HEADER_LINE
	CALL	@CONSOLE.LINE
	RET

COPY_BOUNDED_Z
	LD	A,B
	OR	A
	JR	Z,.TERM
	LD	A,(HL)
	OR	A
	JR	Z,.TERM
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	B
	JR	COPY_BOUNDED_Z
.TERM
	XOR	A
	LD	(DE),A
	RET

; URL parser: absolute http:// only (mirrors WGET's PARSE_URL).
PARSE_URL
	LD	DE,URL_PREFIX
	LD	B,7
.PREFIX
	LD	A,(DE)
	LD	C,A
	LD	A,(HL)
	OR	A
	JP	Z,.BAD
	CALL	TOLOWER
	CP	C
	JP	NZ,.BAD
	INC	HL
	INC	DE
	DJNZ	.PREFIX
	LD	DE,W12_HOST
	LD	B,63
.HOST
	LD	A,(HL)
	OR	A
	JR	Z,.HOST_END
	CP	':'
	JR	Z,.HOST_END
	CP	'/'
	JR	Z,.HOST_END
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.HOST_SKIP
	LD	A,C
	LD	(DE),A
	INC	DE
	DEC	B
.HOST_SKIP
	INC	HL
	JR	.HOST
.HOST_END
	XOR	A
	LD	(DE),A
	LD	DE,80
	LD	(W12_PORT),DE
	LD	A,(HL)
	OR	A
	JR	Z,.DEFAULT_PATH
	CP	'/'
	JR	Z,.COPY_PATH
	CP	':'
	JR	NZ,.BAD
	INC	HL
	LD	DE,0
	LD	B,0
.PORT
	LD	A,(HL)
	SUB	'0'
	JR	C,.PORT_END
	CP	10
	JR	NC,.PORT_END
	INC	B
	LD	C,A
	PUSH	HL
	EX	DE,HL
	ADD	HL,HL
	JR	C,.PORT_OVERFLOW
	LD	D,H
	LD	E,L
	ADD	HL,HL
	JR	C,.PORT_OVERFLOW
	ADD	HL,HL
	JR	C,.PORT_OVERFLOW
	ADD	HL,DE
	JR	C,.PORT_OVERFLOW
	LD	D,0
	LD	E,C
	ADD	HL,DE
	JR	C,.PORT_OVERFLOW
	EX	DE,HL
	POP	HL
	INC	HL
	JR	.PORT
.PORT_OVERFLOW
	POP	HL
	JR	.BAD
.PORT_END
	LD	A,B
	OR	A
	JR	Z,.BAD
	LD	(W12_PORT),DE
	LD	A,D
	OR	E
	JR	Z,.BAD
	LD	A,(HL)
	OR	A
	JR	Z,.DEFAULT_PATH
	CP	'/'
	JR	NZ,.BAD
.COPY_PATH
	LD	DE,W12_PATH
	LD	B,255
	CALL	COPY_BOUNDED_Z
	OR	A
	RET
.DEFAULT_PATH
	LD	HL,DEFAULT_PATH
	LD	DE,W12_PATH
	LD	BC,2
	LDIR
	OR	A
	RET
.BAD
	SCF
	RET

TOLOWER
	CP	'A'
	RET	C
	CP	'Z'+1
	RET	NC
	ADD	A,'a'-'A'
	RET

PRINT_IPV4
	LD	B,4
.IP
	LD	A,(HL)
	CALL	@CONSOLE.DEC8
	INC	HL
	DEC	B
	RET	Z
	LD	A,'.'
	CALL	@CONSOLE.CHAR
	JR	.IP

; ------------------------------------------------------------------
; 32-bit decimal helpers, W12_WORK32/W12_NUMBER_BUFFER scratch (same fields
; WGET uses; the two EXEs never coexist in memory).
; ------------------------------------------------------------------

PRINT_DEC32
	LD	IX,W12_NUMBER_BUFFER
	CALL	FORMAT_DEC32
	LD	(IX+0),0
	LD	HL,W12_NUMBER_BUFFER
	JP	@CONSOLE.STRING

FORMAT_DEC32
	LD	(W12_WORK32),HL
	LD	(W12_WORK32+2),DE
	LD	A,H
	OR	L
	OR	D
	OR	E
	JR	NZ,.NONZERO
	LD	(IX+0),'0'
	INC	IX
	RET
.NONZERO
	LD	B,0
.DIVIDE
	PUSH	BC
	CALL	DIV32_10
	POP	BC
	ADD	A,'0'
	PUSH	AF
	INC	B
	LD	HL,(W12_WORK32)
	LD	A,H
	OR	L
	LD	HL,(W12_WORK32+2)
	OR	H
	OR	L
	JR	NZ,.DIVIDE
.WRITE
	POP	AF
	LD	(IX+0),A
	INC	IX
	DJNZ	.WRITE
	RET

DIV32_10
	LD	HL,0
	LD	B,32
.BIT
	PUSH	HL
	LD	HL,W12_WORK32
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	LD	A,L
	CP	10
	JR	C,.NEXT
	SUB	10
	LD	L,A
	PUSH	HL
	LD	HL,W12_WORK32
	SET	0,(HL)
	POP	HL
.NEXT
	DJNZ	.BIT
	LD	A,L
	RET

; TIME_START/TIME_NOW read DSS_SYSTIME into a seconds-since-midnight value;
; TIME_REPORT compares a saved stop time against it (see CAPTURE_STOP), so
; nothing after the RTC edge alignment reads the clock while unmeasured.
TIME_START
	CALL	TIME_NOW
	LD	(W12_START_TIME),HL
	LD	A,B
	LD	(W12_START_TIME+2),A
	RET

CAPTURE_STOP
	CALL	TIME_NOW
	LD	(W12_ELAPSED),HL
	LD	A,B
	LD	(W12_ELAPSED+2),A
	RET

TIME_NOW
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	PUSH	BC,HL
	LD	HL,0
	LD	(W12_WORK32),HL
	LD	(W12_WORK32+2),HL
	POP	DE
	PUSH	DE
	LD	A,D
	OR	A
	JR	Z,.MINUTES
	LD	B,A
.HOUR_LOOP
	LD	HL,(W12_WORK32)
	LD	DE,3600
	ADD	HL,DE
	LD	(W12_WORK32),HL
	JR	NC,.HOUR_NEXT
	LD	HL,W12_WORK32+2
	INC	(HL)
.HOUR_NEXT
	DJNZ	.HOUR_LOOP
.MINUTES
	POP	DE
	LD	A,E
	OR	A
	JR	Z,.SECONDS
	LD	B,A
.MIN_LOOP
	LD	HL,(W12_WORK32)
	LD	DE,60
	ADD	HL,DE
	LD	(W12_WORK32),HL
	JR	NC,.MIN_NEXT
	LD	HL,W12_WORK32+2
	INC	(HL)
.MIN_NEXT
	DJNZ	.MIN_LOOP
.SECONDS
	POP	BC
	LD	HL,(W12_WORK32)
	LD	D,0
	LD	E,B
	ADD	HL,DE
	LD	A,(W12_WORK32+2)
	LD	B,A
	JR	NC,.NOW_DONE
	INC	B
.NOW_DONE
	POP	IX
	RET

; TIME_REPORT prints "  N bytes in S sec, R KB/s" using W12_ELAPSED
; (CAPTURE_STOP) minus W12_START_TIME (TIME_START). CF=1 for a zero-second
; sample -- too short to trust the rate.
TIME_REPORT
	LD	HL,(W12_ELAPSED)
	LD	DE,(W12_START_TIME)
	OR	A
	SBC	HL,DE
	LD	A,(W12_START_TIME+2)
	LD	E,A
	LD	A,(W12_ELAPSED+2)
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(W12_ELAPSED),HL
	LD	A,B
	LD	(W12_ELAPSED+2),A
	OR	H
	OR	L
	JP	Z,.TOO_SHORT
	LD	HL,MSG_SUMMARY_PREFIX
	CALL	@CONSOLE.STRING
	LD	HL,(W12_BODY_RECEIVED)
	LD	DE,(W12_BODY_RECEIVED+2)
	CALL	PRINT_DEC32
	LD	HL,MSG_SUMMARY_BYTES
	CALL	@CONSOLE.STRING
	LD	HL,(W12_ELAPSED)
	LD	A,(W12_ELAPSED+2)
	LD	E,A
	LD	D,0
	CALL	PRINT_DEC32
	LD	HL,MSG_SUMMARY_SEC
	CALL	@CONSOLE.STRING
	LD	HL,MSG_COMMA
	CALL	@CONSOLE.STRING
	LD	HL,(W12_BODY_RECEIVED)
	LD	(W12_WORK32),HL
	LD	HL,(W12_BODY_RECEIVED+2)
	LD	(W12_WORK32+2),HL
	LD	DE,(W12_ELAPSED)
	CALL	DIV32_BY_DE
	LD	HL,(W12_WORK32+2)
	LD	A,H
	OR	L
	JR	NZ,.KB_RATE
	LD	HL,(W12_WORK32)
	LD	A,H
	CP	4
	JR	NC,.KB_RATE
	LD	DE,(W12_WORK32+2)
	CALL	PRINT_DEC32
	LD	HL,MSG_BPS
	JR	.RATE_SUFFIX
.KB_RATE
	LD	HL,W12_WORK32
	CALL	SHIFT_RIGHT_10
	CALL	PRINT_DEC32
	LD	HL,MSG_KBPS
.RATE_SUFFIX
	CALL	@CONSOLE.STRING
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	OR	A
	RET
.TOO_SHORT
	LD	HL,MSG_SAMPLE_SHORT
	CALL	@CONSOLE.LINE
	SCF
	RET

DIV32_BY_DE
	LD	HL,0
	LD	B,32
.DIV_LOOP
	PUSH	HL
	LD	HL,W12_WORK32
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	POP	HL
	ADC	HL,HL
	JR	C,.SUB_FORCE
	OR	A
	SBC	HL,DE
	JR	C,.RESTORE
	JR	.SET
.SUB_FORCE
	OR	A
	SBC	HL,DE
.SET
	PUSH	HL
	LD	HL,W12_WORK32
	SET	0,(HL)
	POP	HL
	JR	.NEXT
.RESTORE
	ADD	HL,DE
.NEXT
	DJNZ	.DIV_LOOP
	RET

SHIFT_RIGHT_10
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	A,(HL)
	EX	DE,HL
	LD	E,A
	SRL	E
	RR	H
	RR	L
	SRL	E
	RR	H
	RR	L
	LD	D,0
	RET

; ------------------------------------------------------------------
; Exit paths.
; ------------------------------------------------------------------

TCP_OPEN_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(W12_LAST_ERROR),A
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_TCP_OPEN
	JR	TCP_COMMON_FAIL
TCP_SEND_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(W12_LAST_ERROR),A
	LD	HL,MSG_TCP_SEND
	JR	TCP_COMMON_FAIL
TCP_RECV_FAIL_PROTOCOL
	LD	A,NETDRV_ERR_PROTOCOL
TCP_RECV_FAIL
	LD	(W12_LAST_ERROR),A
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_TCP_RECV
TCP_COMMON_FAIL
	CALL	@CONSOLE.STRING
	LD	A,(W12_LAST_ERROR)
	CALL	@CONSOLE.HEX8
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	CALL	PRINT_REGS
	XOR	A
	CALL	@TCPX.ABORT
	LD	B,DSS_EXIT_NETWORK
	JP	FAIL_EXIT

RESOLVE_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	HL,MSG_RESOLVE
	CALL	@CONSOLE.LINE
	LD	B,DSS_EXIT_NETWORK
	JP	FAIL_EXIT

RTC_FAIL
	LD	HL,MSG_RTC_ERROR
	CALL	@CONSOLE.LINE
	XOR	A
	CALL	@TCPX.CLOSE
	LD	B,DSS_EXIT_HARDWARE
	JP	FAIL_EXIT

SAMPLE_TOO_SHORT
	LD	B,DSS_EXIT_REMOTE
	JP	FAIL_EXIT

HTTP_FAIL
	CALL	CAPTURE_STOP
	XOR	A
	CALL	@TCPX.ABORT
	LD	B,DSS_EXIT_REMOTE
	JP	FAIL_EXIT

USER_ABORT
	XOR	A
	CALL	@TCPX.ABORT
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_ABORT
	CALL	@CONSOLE.LINE
	LD	B,DSS_EXIT_CANCELLED
	JP	FAIL_EXIT

PRINT_REGS
	LD	HL,MSG_REGS
	CALL	@CONSOLE.STRING
	LD	A,(NETDRV_SELECTED_SLOT)
	CALL	@CONSOLE.DEC8
	LD	HL,MSG_BASE
	CALL	@CONSOLE.STRING
	LD	HL,(NETDRV_SELECTED_BASE)
	CALL	@CONSOLE.HEX16
	LD	HL,MSG_STATUS
	CALL	@CONSOLE.STRING
	LD	A,(W12_LAST_ERROR)
	CALL	@CONSOLE.HEX8
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

CONFIG_FAIL
	LD	B,DSS_EXIT_CONFIG
	JP	FAIL_EXIT
HARDWARE_FAIL
	LD	B,DSS_EXIT_HARDWARE
	JP	FAIL_EXIT
USAGE_FAIL
	LD	HL,MSG_USAGE_ERROR
	CALL	@CONSOLE.LINE
	LD	HL,MSG_HELP
	CALL	@CONSOLE.STRING
	LD	B,DSS_EXIT_ARGUMENT
	JP	FAIL_EXIT

SUCCESS
	LD	HL,MSG_OK
	CALL	@CONSOLE.STRING
	LD	B,DSS_EXIT_OK
	JR	EXIT_NO_RESULT
FAIL_EXIT
	PUSH	BC
	LD	HL,MSG_FAIL
	CALL	@CONSOLE.STRING
	POP	BC
EXIT_NO_RESULT
	LD	A,B
	LD	(SAVED_EXIT_CODE),A
	LD	A,(S9_TFTP_FILE_OPEN)
	OR	A
	JR	Z,.DRIVER
	LD	A,(S9_TFTP_FILE_HANDLE)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
.DRIVER
	CALL	@NETDRV.DONE
	LD	A,(SAVED_EXIT_CODE)
	LD	B,A
	LD	C,DSS_EXIT
	RST	DSS

; Deliberately silent: reached only when the page claim failed -- see
; wget.asm's BOOT_FAIL for the WIN_MOVE hazard this avoids.
BOOT_FAIL
	DSS_RETURN DSS_EXIT_LOCAL

LIT_CONTENT_LENGTH DB "content-length:",0
LIT_GET		DB "GET ",0
LIT_HTTP_HOST	DB " HTTP/1.0",13,10,"Host: ",0
LIT_REST	DB 13,10,"Connection: close",13,10,13,10,0
URL_PREFIX	DB "http://"
DEFAULT_PATH	DB "/",0

MSG_BANNER	DB "3C509B DLSPEED v",PACKAGE_VERSION,0
MSG_RESOLVED	DB "Resolved ",0
MSG_TO		DB " -> ",0
MSG_PORT	DB " port ",0
MSG_CONNECTED	DB "ESTABLISHED.",0
MSG_WAIT_EDGE	DB "Waiting for RTC edge; transfer is silent until done...",0
MSG_RECEIVED	DB "Received: ",0
MSG_BYTES	DB " bytes",0
MSG_SUMMARY_PREFIX DB "  ",0
MSG_SUMMARY_BYTES DB " bytes in ",0
MSG_SUMMARY_SEC DB " sec",0
MSG_COMMA	DB ", ",0
MSG_KBPS	DB " KB/s",0
MSG_BPS		DB " B/s",0
MSG_REGS	DB "REGS slot=",0
MSG_BASE	DB " base=",0
MSG_STATUS	DB " status=",0
MSG_HTTP_ERROR	DB "[E] ",0
MSG_TCP_OPEN	DB "TCP connect failed, code 0x",0
MSG_TCP_SEND	DB "TCP send failed, code 0x",0
MSG_TCP_RECV	DB "TCP recv failed, code 0x",0
MSG_RESOLVE	DB "[E] could not resolve host.",0
MSG_RTC_ERROR	DB "[E] RTC second did not advance.",0
MSG_SAMPLE_SHORT DB "[E] sample too short (under one RTC second); use a larger file.",0
MSG_ABORT	DB "Aborted by user (Esc/Ctrl+C).",0
MSG_USAGE_ERROR DB "[E] usage: missing or invalid URL",0
MSG_HELP
	DB "Usage:",13,10
	DB "  DLSPEED http://host[:port]/path",13,10
	DB "  DLSPEED /?",13,10,13,10
	DB "  Discards the body while counting it; prints bytes, elapsed",13,10
	DB "  seconds and KB/s once the transfer completes. Use a file of",13,10
	DB "  at least a few hundred KB for a stable measurement.",13,10,0
MSG_OK		DB "RESULT OK",13,10,0
MSG_FAIL	DB "RESULT FAIL",13,10,0

SAVED_EXIT_CODE EQU S10_COMMAND_BUFFER

	ENDMODULE

	INCLUDE "el3_algorithms.asm"
	INCLUDE "console.asm"
	INCLUDE "isa.asm"
	INCLUDE "el3_io.asm"
	INCLUDE "el3_fifo.asm"
	INCLUDE "el3_regs.asm"
	INCLUDE "el3.asm"
	INCLUDE "netdrv.asm"
	INCLUDE "ethernet.asm"
	INCLUDE "../lib/arp.asm"
	INCLUDE "ipv4.asm"
	INCLUDE "tcp.asm"
	INCLUDE "stage9_app.asm"
	INCLUDE "nettime.asm"
	INCLUDE "stage9_cli.asm"
	INCLUDE "tcp_transport.asm"
	INCLUDE "stage11_app.asm"
	INCLUDE "stage12_dns.asm"

	ASSERT $ <= PAGE_BASE
