; FTP.EXE - polling-only PASV FTP client over the 3C509B backend.
; SPDX-License-Identifier: BSD-3-Clause
;
; Unlike the sibling RTL8019A kit's FTP.EXE, the control and data sessions
; are two independent native TCP channels (TCPX channel 0/1): no
; SAVE_CTX/RESTORE_CTX swap is needed, and the control channel keeps
; receiving (e.g. an early "226 Transfer complete") while the data channel
; is still being drained.

EXE_VERSION	EQU 1
; Same standard-layout arrangement as WGET: the image fills WIN1 and claims
; WIN2 for its runtime page, so PAGE_BASE is 8000h and the stack ends up at
; the top of the claimed page.
	DEFINE RUNTIME_BASE 0xB000
	DEFINE STAGE9_LAYOUT
	DEFINE STAGE10_PAGE_LAYOUT
	DEFINE STAGE10_DNS
	DEFINE STAGE11_LAYOUT
	DEFINE STAGE12_LAYOUT
	DEFINE STAGE13_LAYOUT
; STOR is the only bulk upload in the kit, so it is the only image that pays
; for the two-segment send window (tcp_transport.asm's CHOOSE_BURST). WGET and
; DLSPEED send nothing but a request line and would carry the code for
; nothing.
	DEFINE TCPX_SEND_BURST
	; Announce a whole-Ethernet-payload receive MSS (tcp.inc). Costs no image
	; bytes -- constants plus the WIN2 page layout (memory.inc) -- which is
	; what makes it the one throughput lever that fits FTP, whose image has
	; three bytes of headroom. The receive path is charged per segment, so
	; 2.7x fewer segments is 2.7x less of that fixed cost per byte delivered.
	DEFINE TCPX_LARGE_MSS
	; Give the two channels differently sized durable queues
	; (tcp_transport.asm's PENDING_FREE). FTP is the only image with two live
	; channels and they are nothing alike: the data channel wants room for
	; every segment its window promises, the control channel only ever queues
	; the reply that arrives mid-transfer. Sizing both for the data channel
	; spent 1.4 KiB of the WIN2 page on a queue that holds a single line --
	; and that page is the only place RETR's disk buffer can grow, which is
	; what decides how often the transfer stops to call DSS_WRITE.
	DEFINE TCPX_SPLIT_PENDING
	; The receive path DLDIRECT and the DLL already run: one ISA session per
	; frame, the payload read out of the FIFO with its TCP checksum summed in
	; the same pass and landed straight in GET_LOOP's disk buffer, ACKs sent
	; from .WAIT_LOOP rather than from inside frame dispatch, and the eight-
	; byte FIFO burst. Together they halve the Z80 time per received byte,
	; which is where most of RETR's wall time went once the DSS_WRITE batch
	; and the progress repaints had been shown to move nothing. They cost
	; about 1.5 KiB of image, paid for by starting the WIN2 data area 2 KiB
	; above PAGE_BASE (memory.inc's S13_IMAGE_LIMIT).
	DEFINE TCPX_DIRECT_RX
	DEFINE EL3_SESSION_RX
	DEFINE FAST_DATAPATH

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

FTP_CTRL_CHANNEL	EQU 0
FTP_DATA_CHANNEL	EQU 1
FTP_REPLY_TIMEOUT_MS	EQU 5000
FTP_DATA_IDLE_MS	EQU 15000

	ORG 0x4080
	DB "EXE",EXE_VERSION
	DW 0x0080,0,0,0,0,0
	; See wget.asm: the header stack sits at the top of WIN2, 16 KiB clear of
	; the image, which the loader installs before START ever runs.
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
	CALL	CLEAR_FTP_STATE
	CALL	@ARP.CLEAR_CACHE
	CALL	@S9CLI.PARSE_FTP
	JR	NC,.ARGS_OK
	CP	EL3_CLI_HELP
	JP	NZ,USAGE_FAIL
	LD	HL,MSG_HELP
	CALL	@CONSOLE.STRING
	JP	SUCCESS_NO_FILE
.ARGS_OK
	CALL	RESOLVE_MODE
	CALL	DERIVE_ARGS
	CALL	@S9APP.LOAD_ACTIVE_CONFIG
	JP	C,CONFIG_FAIL
	CALL	@S9APP.INIT_DRIVER
	JP	C,HARDWARE_FAIL

	LD	HL,F13_HOST
	CALL	@DNSX.RESOLVE_OR_LITERAL
	JP	C,RESOLVE_FAIL
	LD	HL,MSG_RESOLVED
	CALL	@CONSOLE.STRING
	LD	HL,F13_HOST
	CALL	@CONSOLE.STRING
	LD	HL,MSG_TO
	CALL	@CONSOLE.STRING
	LD	HL,NET_TARGET_IP
	CALL	PRINT_IPV4
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING

	CALL	TIME_START
	CALL	@TCPX.RESET
	XOR	A
	LD	HL,NET_TARGET_IP
	LD	BC,(F13_CTRL_PORT)
	CALL	@TCPX.OPEN
	JP	C,TCP_OPEN_FAIL

	; 220 banner.
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD

	; USER
	LD	HL,CMD_USER
	LD	BC,CMD_USER_LEN
	LD	DE,F13_USER
	CALL	SEND_CMD_ARG_PTR
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	LD	A,(F13_REPLY_CODE)
	CP	'2'
	JR	Z,.AUTH_OK
	CP	'3'
	JP	NZ,REPLY_BAD

	; PASS
	LD	HL,CMD_PASS
	LD	BC,CMD_PASS_LEN
	LD	DE,F13_PASS
	CALL	SEND_CMD_ARG_PTR
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD
.AUTH_OK

	; TYPE I
	LD	HL,CMD_TYPE_I
	LD	BC,CMD_TYPE_I_LEN
	CALL	SEND_CMD
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD

	; SIZE (GET only; a 5xx here is not fatal -- the total just stays "?").
	LD	A,(F13_MODE)
	OR	A
	JR	NZ,.NO_SIZE
	LD	HL,CMD_SIZE
	LD	BC,CMD_SIZE_LEN
	LD	DE,(F13_REMOTE_ARG_PTR)
	CALL	SEND_CMD_ARG_PTR
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	LD	A,(F13_REPLY_CODE)
	CP	'2'
	JR	NZ,.NO_SIZE
	LD	A,(F13_REPLY_CODE+1)
	CP	'1'
	JR	NZ,.NO_SIZE
	LD	A,(F13_REPLY_CODE+2)
	CP	'3'
	JR	NZ,.NO_SIZE
	LD	HL,F13_REPLY_LINE
	CALL	PARSE_DEC32
	JR	C,.NO_SIZE
	LD	(F13_TOTAL_SIZE),HL
	LD	(F13_TOTAL_SIZE+2),DE
	LD	A,1
	LD	(F13_TOTAL_KNOWN),A
.NO_SIZE

	; PASV
	LD	HL,CMD_PASV
	LD	BC,CMD_PASV_LEN
	CALL	SEND_CMD
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	CALL	EXPECT_2XX
	JP	C,REPLY_BAD
	CALL	PARSE_PASV
	JP	C,PASV_FAIL
	LD	HL,MSG_PASV_HDR
	CALL	@CONSOLE.STRING
	LD	HL,F13_DATA_IP
	CALL	PRINT_IPV4
	LD	A,':'
	CALL	@CONSOLE.CHAR
	LD	HL,(F13_DATA_PORT)
	CALL	@CONSOLE.DEC16
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING

	CALL	OPEN_LOCAL_FILE
	JR	NC,.FILE_READY
	CP	NETDRV_ERR_CANCELLED
	JP	Z,PROMPT_CANCEL
	JP	FILE_FAIL
.FILE_READY
	; A repeated -r against an already complete local file is a successful
	; no-op. Opening a PASV data connection and issuing REST exactly at EOF is
	; legal, but a number of small/test servers never close that empty stream;
	; SIZE already gives us an unambiguous answer without entering that trap.
	LD	A,(F13_MODE)
	OR	A
	JR	NZ,.TRANSFER_NEEDED
	LD	A,(F13_RESUME_SELECTED)
	OR	A
	JR	Z,.TRANSFER_NEEDED
	LD	A,(F13_TOTAL_KNOWN)
	OR	A
	JR	Z,.TRANSFER_NEEDED
	LD	HL,F13_RESUME_OFFSET
	LD	DE,F13_TOTAL_SIZE
	LD	B,4
.RESUME_SIZE_COMPARE
	LD	A,(DE)
	CP	(HL)
	JR	NZ,.TRANSFER_NEEDED
	INC	DE
	INC	HL
	DJNZ	.RESUME_SIZE_COMPARE
	CALL	CLOSE_LOCAL_FILE
	JP	C,FILE_FAIL
	JP	TRANSFER_SUMMARY
.TRANSFER_NEEDED

	LD	HL,MSG_OPENING_DATA
	CALL	@CONSOLE.LINE
	LD	A,FTP_DATA_CHANNEL
	LD	HL,F13_DATA_IP
	LD	BC,(F13_DATA_PORT)
	CALL	@TCPX.OPEN
	JP	C,DATA_OPEN_FAIL

	; REST (GET resume only).
	LD	A,(F13_MODE)
	OR	A
	JR	NZ,.NO_REST
	LD	HL,(F13_RESUME_OFFSET)
	LD	DE,(F13_RESUME_OFFSET+2)
	LD	A,H
	OR	L
	OR	D
	OR	E
	JR	Z,.NO_REST
	LD	HL,CMD_REST
	LD	DE,S11_APP_BUFFER
	LD	BC,CMD_REST_LEN
	LDIR
	LD	HL,(F13_RESUME_OFFSET)
	LD	DE,(F13_RESUME_OFFSET+2)
	LD	IX,S11_APP_BUFFER+CMD_REST_LEN
	CALL	FORMAT_DEC32
	PUSH	IX
	POP	HL
	LD	A,13
	LD	(HL),A
	INC	HL
	LD	A,10
	LD	(HL),A
	INC	HL
	LD	DE,S11_APP_BUFFER
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,S11_APP_BUFFER
	LD	A,FTP_CTRL_CHANNEL
	CALL	@TCPX.SEND
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	LD	A,(F13_REPLY_CODE)
	CP	'3'
	JP	NZ,REST_REFUSED
.NO_REST

	; RETR / STOR / LIST/NLST. A 5xx NLST refusal retries LIST on this same
	; already-open PASV data channel; bit 4 is cleared before that retry.
	LD	A,(F13_MODE)
	CP	1
	JR	Z,.SEND_STOR
	CP	2
	JR	Z,.SEND_LIST_VERB
	LD	HL,CMD_RETR
	LD	BC,CMD_RETR_LEN
	JR	.SEND_VERB
.SEND_STOR
	LD	HL,CMD_STOR
	LD	BC,CMD_STOR_LEN
	JR	.SEND_VERB
.SEND_LIST_VERB
	LD	A,(F13_FLAGS)
	BIT	F13_FLAG_NLST_BIT,A
	JR	Z,.SEND_LIST
	LD	HL,CMD_NLST
	LD	BC,CMD_NLST_LEN
	JR	.SEND_VERB
.SEND_LIST
	LD	HL,CMD_LIST
	LD	BC,CMD_LIST_LEN
.SEND_VERB
	LD	DE,(F13_REMOTE_ARG_PTR)
	CALL	SEND_CMD_ARG_PTR
	JP	C,TCP_FAIL
	CALL	READ_REPLY
	JP	C,REPLY_FAIL
	CALL	PRINT_REPLY
	LD	A,(F13_REPLY_CODE)
	CP	'1'
	JP	Z,.VERB_OK
	CP	'2'
	JP	Z,.VERB_OK
	LD	A,(F13_FLAGS)
	BIT	F13_FLAG_NLST_BIT,A
	JP	Z,REPLY_BAD
	LD	A,(F13_REPLY_CODE)
	CP	'5'
	JP	NZ,REPLY_BAD
	LD	HL,F13_FLAGS
	RES	F13_FLAG_NLST_BIT,(HL)
	LD	HL,MSG_NLST_FALLBACK
	CALL	@CONSOLE.STRING
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	JP	.SEND_LIST_VERB
.VERB_OK
	LD	A,(F13_MODE)
	CP	1
	JP	Z,PUT_LOOP
	CP	2
	JP	Z,LIST_LOOP
	JP	GET_LOOP

; FINAL_PROGRESS repaints the counter one last time, unconditionally, and
; falls into TRANSFER_DONE. GET and PUT both enter here rather than through
; TRANSFER_DONE directly: PROGRESS_TICK only repaints every fourth flush, so
; without this the last figure on screen would be whatever the last
; multiple-of-four flush showed -- or, on a transfer shorter than four
; flushes, nothing at all. LIST has no counter and still enters below.
FINAL_PROGRESS
	CALL	PRINT_PROGRESS
; TRANSFER_DONE is the common landing point once GET_LOOP/PUT_LOOP/LIST_LOOP
; finish normally (peer closed the data channel / local EOF reached).
TRANSFER_DONE
	CALL	CLOSE_LOCAL_FILE
	JP	C,FILE_FAIL
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.CLOSE
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	; The "226 Transfer complete" reply is informational; a timeout or a
	; garbled read here is not fatal, matching the sibling's own leniency.
	CALL	READ_REPLY
	JR	C,.NO226
	CALL	PRINT_REPLY
.NO226
TRANSFER_SUMMARY
	LD	A,(F13_MODE)
	CP	2
	JR	Z,.SKIP_SUMMARY
	LD	HL,MSG_DONE_PRE
	CALL	@CONSOLE.STRING
	LD	HL,(F13_TRANSFERRED)
	LD	DE,(F13_TRANSFERRED+2)
	CALL	PRINT_DEC32
	LD	A,(F13_MODE)
	CP	1
	JR	Z,.SENT_MSG
	LD	HL,MSG_BYTES
	CALL	@CONSOLE.LINE
	JR	.RATE
.SENT_MSG
	LD	HL,MSG_BYTES_SENT
	CALL	@CONSOLE.LINE
.RATE
	CALL	TIME_REPORT
.SKIP_SUMMARY
	LD	HL,CMD_QUIT
	LD	BC,CMD_QUIT_LEN
	CALL	SEND_CMD
	CALL	READ_REPLY
	JR	C,.QDONE
	CALL	PRINT_REPLY
.QDONE
	XOR	A
	CALL	@TCPX.CLOSE
	JP	SUCCESS_NO_FILE

; GET_LOOP receives directly into STAGE9_FILE_BUFFER+used. Under
; EL3_SESSION_RX a segment goes from the card's FIFO straight to that address
; only while a whole TCP_MSS still fits there; anything smaller is promised
; from the durable pending queue and copied out of it, an extra pass over
; every byte that takes that route. So the request is always exactly one
; whole segment, and the buffer is flushed as soon as one no longer fits:
; FLUSH_SECTORS writes the whole 512-byte sectors staged so far and slides
; the sub-sector remainder down to the start of the buffer, which keeps every
; DSS_WRITE sector-aligned (the file position only ever advances by whole
; sectors) without ever asking RECV for a partial segment.
GET_LOOP
	LD	DE,(F13_BUFFER_USED)
	LD	HL,STAGE9_FILE_CAPACITY-TCP_MSS
	OR	A
	SBC	HL,DE			; CF: less than one segment free
	JR	NC,.REQUEST
	CALL	FLUSH_SECTORS
	JP	C,FILE_FAIL
	JR	GET_LOOP
.REQUEST
	LD	HL,STAGE9_FILE_BUFFER
	ADD	HL,DE
	LD	BC,TCP_MSS
	LD	DE,FTP_DATA_IDLE_MS
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.RECV
	JR	C,.END_OR_FAIL
	LD	HL,(F13_BUFFER_USED)
	ADD	HL,BC
	LD	(F13_BUFFER_USED),HL
	LD	D,B
	LD	E,C
	LD	HL,F13_TRANSFERRED
	CALL	ADD16_TO_32
	JR	GET_LOOP
.END_OR_FAIL
	CP	TCP_ERR_CLOSED
	JR	Z,.PEER_CLOSED
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	JP	DATA_RX_FAIL
.PEER_CLOSED
	CALL	FLUSH_BUFFER
	JP	C,FILE_FAIL
	JP	FINAL_PROGRESS

; LIST_LOOP streams the data channel straight to the console instead of a
; file. One byte of the request capacity is held back so the in-place NUL
; trick in PRINT_DATA_CHUNK never writes past S11_APP_BUFFER.
LIST_LOOP
	LD	A,FTP_DATA_CHANNEL
	LD	HL,S11_APP_BUFFER
	LD	BC,S11_APP_CAPACITY-1
	LD	DE,FTP_DATA_IDLE_MS
	CALL	@TCPX.RECV
	JR	C,.END_OR_FAIL
	LD	A,B
	OR	C
	JR	Z,LIST_LOOP
	CALL	PRINT_DATA_CHUNK
	JR	LIST_LOOP
.END_OR_FAIL
	CP	TCP_ERR_CLOSED
	JP	Z,TRANSFER_DONE
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	JP	DATA_RX_FAIL

PRINT_DATA_CHUNK
	LD	HL,S11_APP_BUFFER
	ADD	HL,BC
	LD	A,(HL)
	LD	(.SAVE),A
	XOR	A
	LD	(HL),A
	LD	HL,S11_APP_BUFFER
	CALL	@CONSOLE.STRING
	LD	HL,S11_APP_BUFFER
	ADD	HL,BC
	LD	A,(.SAVE)
	LD	(HL),A
	RET
.SAVE	DB 0

; PUT_LOOP fills STAGE9_FILE_BUFFER with one DSS read (2 KiB) and hands the
; whole chunk to one SEND call; TCPX.SEND segments and ACKs it internally,
; so there is no manual per-MSS slicing to do here.
PUT_LOOP
	LD	HL,STAGE9_FILE_BUFFER
	LD	DE,STAGE9_FILE_CAPACITY
	LD	A,(F13_FILE_HANDLE)
	CALL	@FILE.READ_CHUNK
	JP	C,FILE_FAIL
	LD	A,D
	OR	E
	JP	Z,FINAL_PROGRESS
	LD	(F13_CHUNK_LEN),DE
	PUSH	DE
	POP	BC
	LD	HL,STAGE9_FILE_BUFFER
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.SEND
	JP	C,.SEND_FAIL
	LD	DE,(F13_CHUNK_LEN)
	LD	HL,F13_TRANSFERRED
	CALL	ADD16_TO_32
	CALL	PROGRESS_TICK
	JP	PUT_LOOP
.SEND_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	JP	DATA_RX_FAIL

ADD16_TO_32
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	DEC	HL
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET	NC
	INC	HL
	INC	(HL)
	RET	NZ
	INC	HL
	INC	(HL)
	RET

; FLUSH_BUFFER writes everything staged; the transfer's end and error
; cleanup use it, since the file's last sector is allowed to be partial.
FLUSH_BUFFER
	LD	DE,(F13_BUFFER_USED)
	LD	A,D
	OR	E
	RET	Z
	CALL	WRITE_STAGED
	RET	C
	LD	HL,0
	LD	(F13_BUFFER_USED),HL
	RET

; FLUSH_SECTORS writes only the whole sectors staged (F13_BUFFER_USED rounded
; down to 512) and moves the remainder to the start of the buffer. GET_LOOP
; calls it when less than a segment is free, and the capacity ASSERT in
; memory.inc guarantees that at least one whole sector is staged by then,
; so the loop always makes progress. The slide is under 512 bytes per
; segment received -- a small fraction of the copy the alternative (asking
; RECV for the partial remainder, which routes a whole segment through the
; pending queue) would cost.
; Out: CF=1/A=NETDRV_ERR_FILE_IO on a write failure. Clobbers all.
FLUSH_SECTORS
	LD	HL,(F13_BUFFER_USED)
	LD	A,H
	AND	0xFE
	LD	D,A
	LD	E,0			; DE = whole sectors staged
	PUSH	HL
	PUSH	DE
	CALL	WRITE_STAGED
	POP	DE
	POP	HL
	RET	C
	OR	A
	SBC	HL,DE			; HL = remainder, under one sector
	LD	(F13_BUFFER_USED),HL
	LD	A,H
	OR	L
	RET	Z
	LD	B,H
	LD	C,L
	LD	HL,STAGE9_FILE_BUFFER
	ADD	HL,DE
	LD	DE,STAGE9_FILE_BUFFER
	LDIR
	XOR	A
	RET

; WRITE_STAGED: one DSS_WRITE of DE bytes from the start of the buffer,
; preceded by the progress tick. In: DE=length (>0).
; Out: CF=1/A=NETDRV_ERR_FILE_IO on failure. Clobbers all.
WRITE_STAGED
	PUSH	DE
	CALL	PROGRESS_TICK
	POP	DE
	LD	HL,STAGE9_FILE_BUFFER
	LD	A,(F13_FILE_HANDLE)
	LD	C,DSS_WRITE
	RST	DSS
	RET	NC
	LD	A,NETDRV_ERR_FILE_IO
	SCF
	RET

; Error cleanup preserves the pending partial body without adding a late
; progress repaint after the already-printed diagnostic.
FLUSH_BUFFER_QUIET
	LD	DE,(F13_BUFFER_USED)
	LD	A,D
	OR	E
	RET	Z
	LD	HL,STAGE9_FILE_BUFFER
	LD	A,(F13_FILE_HANDLE)
	LD	C,DSS_WRITE
	RST	DSS
	RET	C
	LD	HL,0
	LD	(F13_BUFFER_USED),HL
	RET

; PROGRESS_TICK runs once per disk-buffer flush or upload chunk, with the
; ISA window closed. Only every sixteenth one repaints the counter, for the
; reason the sibling RTL8019A kit decimates its own: the repaint is a
; carriage return plus a dozen DSS console characters and two 32-bit decimal
; conversions on the transfer's critical path. RETR now flushes about once
; per received segment (see GET_LOOP), so sixteen flushes is roughly 20 KiB
; -- the same cadence the sibling's fourth-of-8-KiB gives, still a few
; updates a second at any rate worth watching. The final repaint is forced
; by the transfer's own end, so the last figure is always exact.
;
; .DOT is placed first so the common path falls straight through into
; PRINT_PROGRESS instead of spending a CALL/RET on it.
PROGRESS_DOT
	LD	A,'.'
	JP	@CONSOLE.CHAR
PROGRESS_TICK
	LD	A,(F13_FLAGS)
	BIT	2,A
	JR	NZ,PROGRESS_DOT
	LD	HL,F13_PROGRESS_COUNT
	INC	(HL)
	LD	A,(HL)
	AND	15
	RET	NZ
	; fall through into PRINT_PROGRESS

; PRINT_PROGRESS prints an in-place "X / Y" line. Unlike WGET's HTTP
; Content-Length under a partial 206, FTP's SIZE reply is always the whole
; remote file, so Y is not adjusted by the resume offset -- only X is.
PRINT_PROGRESS
	LD	A,(F13_FLAGS)
	BIT	2,A
	RET	NZ
	LD	A,13
	CALL	@CONSOLE.CHAR
	LD	HL,(F13_TRANSFERRED)
	LD	DE,(F13_RESUME_OFFSET)
	ADD	HL,DE
	LD	(F13_TOTAL_WRITTEN),HL
	LD	HL,(F13_TRANSFERRED+2)
	LD	DE,(F13_RESUME_OFFSET+2)
	ADC	HL,DE
	LD	(F13_TOTAL_WRITTEN+2),HL
	LD	HL,F13_TOTAL_WRITTEN
	CALL	PRINT_KB
	LD	HL,MSG_PROGRESS_MID
	CALL	@CONSOLE.STRING
	LD	A,(F13_TOTAL_KNOWN)
	OR	A
	JR	Z,.UNKNOWN
	LD	HL,(F13_TOTAL_SIZE)
	LD	DE,(F13_TOTAL_SIZE+2)
	LD	A,H
	OR	L
	OR	D
	OR	E
	JR	Z,.UNKNOWN
	LD	HL,F13_TOTAL_SIZE
	CALL	PRINT_KB
	JR	.TAIL
.UNKNOWN
	LD	A,'?'
	CALL	@CONSOLE.CHAR
.TAIL
	LD	HL,MSG_PROGRESS_KB
	JP	@CONSOLE.STRING

; KB_OF: HL -> 32-bit little-endian byte count. Out: HL:DE = whole KB.
; Takes bytes 1..3 (the value shifted right eight) and shifts twice more, so
; no 32-bit shift loop is needed. TIME_REPORT divides the result by the
; elapsed seconds, which is why this is split out of PRINT_KB.
KB_OF
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

PRINT_KB
	CALL	KB_OF
	JP	PRINT_DEC32

; RESOLVE_MODE turns PARSE_FTP's raw F13_MODE (0 unless PUT was seen) into
; the final 0 GET / 1 PUT / 2 LIST, now that every flag has been read.
RESOLVE_MODE
	LD	A,(F13_MODE)
	OR	A
	RET	NZ
	LD	A,(F13_FLAGS)
	AND	F13_FLAG_LIST_MASK
	RET	Z
	LD	A,2
	LD	(F13_MODE),A
	RET

; DERIVE_ARGS resolves F13_LOCAL_ARG_PTR/F13_REMOTE_ARG_PTR: the wire path
; and the local file, applying -o (staged in F13_OUTPUT_OVERRIDE by
; PARSE_FTP) on whichever side is mode-relevant.
DERIVE_ARGS
	LD	A,(F13_MODE)
	CP	1
	JR	Z,.PUT
	LD	HL,F13_REMOTE_PATH
	LD	(F13_REMOTE_ARG_PTR),HL
	LD	A,(F13_MODE)
	CP	2
	RET	Z
	LD	A,(F13_FLAGS)
	BIT	5,A
	JR	Z,.GET_DEFAULT
	LD	HL,F13_OUTPUT_OVERRIDE
	LD	(F13_LOCAL_ARG_PTR),HL
	RET
.GET_DEFAULT
	LD	HL,F13_REMOTE_PATH
	CALL	@FILE.BASENAME
	LD	(F13_LOCAL_ARG_PTR),HL
	RET
.PUT
	LD	HL,F13_LOCAL_OUTPUT
	LD	(F13_LOCAL_ARG_PTR),HL
	LD	A,(F13_FLAGS)
	BIT	5,A
	JR	Z,.PUT_DEFAULT
	LD	HL,F13_OUTPUT_OVERRIDE
	LD	(F13_REMOTE_ARG_PTR),HL
	RET
.PUT_DEFAULT
	LD	HL,F13_LOCAL_OUTPUT
	CALL	@FILE.BASENAME
	LD	(F13_REMOTE_ARG_PTR),HL
	RET

OPEN_LOCAL_FILE
	LD	A,(F13_MODE)
	CP	2
	JR	Z,.NONE
	CP	1
	JR	Z,.PUT
	LD	A,(F13_FLAGS)
	BIT	1,A
	LD	A,2
	JR	NZ,.MODE
	LD	A,(F13_FLAGS)
	AND	1
.MODE
	LD	HL,(F13_LOCAL_ARG_PTR)
	CALL	@FILE.OPEN_OUTPUT_ORC
	RET	C
	LD	(F13_FILE_HANDLE),A
	LD	(S9_TFTP_FILE_HANDLE),A
	LD	A,1
	LD	(F13_FILE_OPEN),A
	LD	(S9_TFTP_FILE_OPEN),A
	XOR	A
	RET
.PUT
	LD	HL,(F13_LOCAL_ARG_PTR)
	CALL	@FILE.OPEN_INPUT
	RET	C
	LD	(F13_FILE_HANDLE),A
	LD	(S9_TFTP_FILE_HANDLE),A
	LD	A,1
	LD	(F13_FILE_OPEN),A
	LD	(S9_TFTP_FILE_OPEN),A
	LD	A,(F13_FILE_HANDLE)
	LD	B,SEEK_END
	LD	HL,0
	LD	IX,0
	LD	C,DSS_MOVE_FP
	RST	DSS
	JR	C,.SIZE_DONE
	LD	(F13_TOTAL_SIZE),IX
	LD	(F13_TOTAL_SIZE+2),HL
	LD	A,1
	LD	(F13_TOTAL_KNOWN),A
	LD	A,(F13_FILE_HANDLE)
	LD	B,SEEK_SET
	LD	HL,0
	LD	IX,0
	LD	C,DSS_MOVE_FP
	RST	DSS
	RET	C
.SIZE_DONE
	XOR	A
	RET
.NONE
	XOR	A
	RET

CLOSE_LOCAL_FILE
	LD	A,(F13_FILE_OPEN)
	OR	A
	RET	Z
	LD	A,(F13_FILE_HANDLE)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	RET	C
	XOR	A
	LD	(F13_FILE_OPEN),A
	LD	(S9_TFTP_FILE_OPEN),A
	RET

CLEAR_FTP_STATE
	LD	HL,F13_STATE_BASE
	LD	B,0x48
	XOR	A
.CLEAR
	LD	(HL),A
	INC	HL
	DJNZ	.CLEAR
	LD	A,0xFF
	LD	(F13_FILE_HANDLE),A
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
; FTP control-reply reader.
; ------------------------------------------------------------------

; READ_REPLY reads one complete reply (single- or multi-line) from the
; control channel. Out: F13_REPLY_CODE = three ASCII digits, F13_REPLY_LINE
; = ASCIIZ text after "ddd ". CF=1 on connection close/timeout/reset/cancel.
READ_REPLY
	; No accumulator reset here. Whatever CONSUME_LINE left behind is the
	; front of the *next* reply, not stale bytes: a server is free to
	; pipeline "150 ...\r\n226 ...\r\n" into one segment for a small
	; transfer, and clearing the buffer on entry dropped the 226 that had
	; already arrived -- then waited out the reply timeout for a copy that
	; was never coming. CLEAR_FTP_STATE zeroes F13_ACCUM_LEN once at start.
.LOOP
	CALL	FIND_LINE
	JP	C,.NEED_MORE
	LD	HL,(F13_LINE_LEN)
	LD	A,H
	OR	L
	JP	Z,.CONSUME
	LD	HL,(F13_LINE_LEN)
	LD	DE,4
	OR	A
	SBC	HL,DE
	JP	C,.CONSUME
	LD	HL,F13_ACCUM_BUF
	LD	A,(HL)
	CALL	IS_DIGIT
	JP	NC,.CONSUME
	INC	HL
	LD	A,(HL)
	CALL	IS_DIGIT
	JP	NC,.CONSUME
	INC	HL
	LD	A,(HL)
	CALL	IS_DIGIT
	JP	NC,.CONSUME
	INC	HL
	LD	A,(HL)
	CP	' '
	JP	NZ,.CONSUME
	; Final reply line: extract before consuming it out of the accumulator.
	LD	HL,F13_ACCUM_BUF
	LD	DE,F13_REPLY_CODE
	LD	BC,3
	LDIR
	LD	HL,(F13_LINE_LEN)
	LD	DE,4
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	A,B
	OR	C
	JR	Z,.EMPTY_TEXT
	; F13_REPLY_LINE holds 256 bytes but the accumulator holds 512, so a
	; reply line longer than that -- some real 220 banners are -- has to be
	; truncated here or the copy writes straight through F13_SAVED_CWD.
	LD	A,B
	OR	A
	JR	Z,.LEN_OK
	LD	BC,255
.LEN_OK
	LD	HL,F13_ACCUM_BUF+4
	LD	DE,F13_REPLY_LINE
	LDIR
	XOR	A
	LD	(DE),A
	JR	.FINAL_DONE
.EMPTY_TEXT
	XOR	A
	LD	(F13_REPLY_LINE),A
.FINAL_DONE
	CALL	CONSUME_LINE
	OR	A
	RET
.CONSUME
	CALL	CONSUME_LINE
	JP	.LOOP
.NEED_MORE
	LD	HL,S11_APP_BUFFER
	LD	BC,S11_APP_CAPACITY
	LD	DE,FTP_REPLY_TIMEOUT_MS
	XOR	A
	CALL	@TCPX.RECV
	JP	C,.FAIL
	LD	HL,S11_APP_BUFFER	; RECV clobbers HL; APPEND_TO_ACCUM needs it
	CALL	APPEND_TO_ACCUM
	JP	.LOOP
.FAIL
	SCF
	RET

; FIND_LINE: does F13_ACCUM_BUF contain a complete CRLF-terminated line at
; its front? New bytes are only ever appended at the end, so the first line
; is always already at offset 0. CF=0: F13_LINE_LEN set, bytes left in place
; for the caller to inspect. CF=1: not yet, caller must read more.
FIND_LINE
	LD	HL,F13_ACCUM_BUF
	LD	BC,(F13_ACCUM_LEN)
.SCAN
	LD	A,B
	OR	A
	JR	NZ,.HAVE2
	LD	A,C
	CP	2
	JR	C,.NF
.HAVE2
	LD	A,(HL)
	CP	13
	JR	NZ,.NX
	INC	HL
	LD	A,(HL)
	CP	10
	JR	Z,.FOUND
	DEC	HL
.NX
	INC	HL
	DEC	BC
	JR	.SCAN
.NF
	SCF
	RET
.FOUND
	LD	DE,F13_ACCUM_BUF+1
	OR	A
	SBC	HL,DE
	LD	(F13_LINE_LEN),HL
	OR	A
	RET

; CONSUME_LINE removes F13_LINE_LEN+2 bytes (the line just inspected, plus
; its CRLF) from the front of F13_ACCUM_BUF, shifting whatever follows down.
CONSUME_LINE
	LD	HL,(F13_LINE_LEN)
	LD	DE,2
	ADD	HL,DE
	EX	DE,HL
	LD	HL,(F13_ACCUM_LEN)
	OR	A
	SBC	HL,DE
	LD	(F13_ACCUM_LEN),HL
	LD	B,H
	LD	C,L
	LD	A,B
	OR	C
	RET	Z
	LD	HL,F13_ACCUM_BUF
	ADD	HL,DE
	LD	DE,F13_ACCUM_BUF
	LDIR
	RET

; APPEND_TO_ACCUM appends BC bytes at HL to F13_ACCUM_BUF, capped at its
; 512-byte capacity (excess is dropped; a reply line never needs that much).
APPEND_TO_ACCUM
	LD	A,B
	OR	C
	RET	Z
	PUSH	HL
	LD	HL,512
	LD	DE,(F13_ACCUM_LEN)
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	L
	JR	Z,.DROP
	EX	DE,HL			; DE = available
	LD	A,B
	CP	D
	JR	C,.NOCAP
	JR	NZ,.CAP
	LD	A,C
	CP	E
	JR	C,.NOCAP
	JR	Z,.NOCAP
.CAP
	LD	B,D
	LD	C,E
.NOCAP
	LD	HL,F13_ACCUM_BUF
	LD	DE,(F13_ACCUM_LEN)
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	PUSH	BC
	LDIR
	POP	BC
	LD	HL,(F13_ACCUM_LEN)
	ADD	HL,BC
	LD	(F13_ACCUM_LEN),HL
	RET
.DROP
	POP	HL
	RET

IS_DIGIT
	CP	'0'
	JR	C,.NO
	CP	'9'+1
	JR	NC,.NO
	SCF
	RET
.NO
	OR	A
	RET

PRINT_REPLY
	LD	HL,F13_REPLY_CODE
	LD	B,3
.LP
	LD	A,(HL)
	PUSH	HL,BC
	CALL	@CONSOLE.CHAR
	POP	BC,HL
	INC	HL
	DJNZ	.LP
	LD	A,' '
	CALL	@CONSOLE.CHAR
	LD	HL,F13_REPLY_LINE
	CALL	@CONSOLE.LINE
	RET

EXPECT_2XX
	LD	A,(F13_REPLY_CODE)
	CP	'2'
	JR	NZ,.NO
	OR	A
	RET
.NO
	SCF
	RET

; SEND_CMD: HL=verb text (no CRLF), BC=verb length. Sends "verb\r\n" on the
; control channel.
SEND_CMD
	LD	DE,S11_APP_BUFFER
	PUSH	BC
	LDIR
	LD	A,13
	LD	(DE),A
	INC	DE
	LD	A,10
	LD	(DE),A
	POP	BC
	INC	BC
	INC	BC
	LD	HL,S11_APP_BUFFER
	LD	A,FTP_CTRL_CHANNEL
	JP	@TCPX.SEND

; SEND_CMD_ARG_PTR: HL=verb (incl trailing space), BC=verb length, DE=ASCIIZ
; argument. Sends "verb argtext\r\n"; an empty argument drops the verb's
; trailing space so a bare command goes out ("LIST\r\n") instead of one with
; a literal trailing space, which some servers treat as a nonexistent path.
SEND_CMD_ARG_PTR
	PUSH	DE
	LD	DE,S11_APP_BUFFER
	LDIR
	POP	HL
	LD	A,(HL)
	OR	A
	JR	Z,.NOARG
.COPYARG
	LD	A,(HL)
	OR	A
	JR	Z,.CRLF
	LD	(DE),A
	INC	HL
	INC	DE
	JR	.COPYARG
.NOARG
	DEC	DE
.CRLF
	LD	A,13
	LD	(DE),A
	INC	DE
	LD	A,10
	LD	(DE),A
	INC	DE
	LD	HL,S11_APP_BUFFER
	EX	DE,HL
	OR	A
	SBC	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,S11_APP_BUFFER
	LD	A,FTP_CTRL_CHANNEL
	JP	@TCPX.SEND

; PARSE_PASV: parse "227 ... (h1,h2,h3,h4,p1,p2)" from F13_REPLY_LINE into
; F13_DATA_IP (4 bytes) and F13_DATA_PORT (port = p1*256 + p2).
PARSE_PASV
	LD	HL,F13_REPLY_LINE
.FP
	LD	A,(HL)
	OR	A
	JR	Z,.BAD
	CP	'('
	JR	Z,.GO
	INC	HL
	JR	.FP
.GO
	INC	HL
	LD	DE,F13_DATA_IP
	LD	B,4
.OCT
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.PORTH
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	JR	.OCT
.PORTH
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	B,A
	LD	A,(HL)
	CP	','
	JR	NZ,.BAD
	INC	HL
	CALL	PARSE_DEC_BYTE_LOC
	JR	C,.BAD
	LD	L,A
	LD	H,B
	LD	(F13_DATA_PORT),HL
	OR	A
	RET
.BAD
	SCF
	RET

; PARSE_DEC_BYTE_LOC: read 1..3 decimal digits at (HL), return byte in A;
; advance HL past digits. Preserves DE (PARSE_PASV's IP write pointer).
PARSE_DEC_BYTE_LOC
	PUSH	BC
	PUSH	DE
	LD	C,0
	LD	B,0
.LP
	LD	A,(HL)
	CALL	IS_DIGIT
	JR	NC,.END
	SUB	'0'
	LD	D,A
	LD	A,C
	ADD	A,A
	ADD	A,A
	ADD	A,C
	ADD	A,A
	ADD	A,D
	LD	C,A
	INC	HL
	INC	B
	LD	A,B
	CP	3
	JR	C,.LP
.END
	LD	A,B
	OR	A
	JR	Z,.BAD
	LD	A,C
	POP	DE
	POP	BC
	OR	A
	RET
.BAD
	POP	DE
	POP	BC
	SCF
	RET

; ------------------------------------------------------------------
; 32-bit decimal helpers, F13_WORK32/F13_NUMBER_BUFFER scratch.
; ------------------------------------------------------------------

PRINT_DEC32
	LD	IX,F13_NUMBER_BUFFER
	CALL	FORMAT_DEC32
	LD	(IX+0),0
	LD	HL,F13_NUMBER_BUFFER
	JP	@CONSOLE.STRING

FORMAT_DEC32
	LD	(F13_WORK32),HL
	LD	(F13_WORK32+2),DE
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
	LD	HL,(F13_WORK32)
	LD	A,H
	OR	L
	LD	HL,(F13_WORK32+2)
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
	LD	HL,F13_WORK32
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
	LD	HL,F13_WORK32
	SET	0,(HL)
	POP	HL
.NEXT
	DJNZ	.BIT
	LD	A,L
	RET

; PARSE_DEC32: HL -> decimal text. Out: HL:DE = value, CF=1 if no digits.
PARSE_DEC32
	LD	DE,0
	LD	(F13_WORK32),DE
	LD	(F13_WORK32+2),DE
	LD	B,0
.NEXT
	LD	A,(HL)
	SUB	'0'
	JR	C,.DONE
	CP	10
	JR	NC,.DONE
	INC	B
	LD	C,A
	PUSH	HL
	CALL	MUL_WORK32_10
	LD	A,(F13_WORK32)
	ADD	A,C
	LD	(F13_WORK32),A
	JR	NC,.NO_CARRY
	LD	HL,F13_WORK32+1
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
.DONE
	LD	A,B
	OR	A
	JR	Z,.BAD
	LD	HL,(F13_WORK32)
	LD	DE,(F13_WORK32+2)
	OR	A
	RET
.BAD
	SCF
	RET

MUL_WORK32_10
	CALL	SHIFT_WORK32		; 2x, retained as the addend
	LD	HL,(F13_WORK32)
	LD	DE,(F13_WORK32+2)
	LD	(F13_TOTAL_WRITTEN),HL
	LD	(F13_TOTAL_WRITTEN+2),DE
	CALL	SHIFT_WORK32		; 4x
	CALL	SHIFT_WORK32		; 8x
	LD	HL,(F13_WORK32)
	LD	DE,(F13_TOTAL_WRITTEN)
	ADD	HL,DE
	LD	(F13_WORK32),HL
	LD	HL,(F13_WORK32+2)
	LD	DE,(F13_TOTAL_WRITTEN+2)
	ADC	HL,DE
	LD	(F13_WORK32+2),HL
	RET

SHIFT_WORK32
	LD	HL,F13_WORK32
	SLA	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	INC	HL
	RL	(HL)
	RET

TIME_START
	CALL	TIME_NOW
	LD	(F13_START_TIME),HL
	LD	A,B
	LD	(F13_START_TIME+2),A
	RET

TIME_NOW
	PUSH	IX
	LD	C,DSS_SYSTIME
	RST	DSS
	PUSH	BC,HL
	LD	HL,0
	LD	(F13_WORK32),HL
	LD	(F13_WORK32+2),HL
	POP	DE
	PUSH	DE
	LD	A,D
	OR	A
	JR	Z,.MINUTES
	LD	B,A
.HOUR_LOOP
	LD	HL,(F13_WORK32)
	LD	DE,3600
	ADD	HL,DE
	LD	(F13_WORK32),HL
	JR	NC,.HOUR_NEXT
	LD	HL,F13_WORK32+2
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
	LD	HL,(F13_WORK32)
	LD	DE,60
	ADD	HL,DE
	LD	(F13_WORK32),HL
	JR	NC,.MIN_NEXT
	LD	HL,F13_WORK32+2
	INC	(HL)
.MIN_NEXT
	DJNZ	.MIN_LOOP
.SECONDS
	POP	BC
	LD	HL,(F13_WORK32)
	LD	D,0
	LD	E,B
	ADD	HL,DE
	LD	A,(F13_WORK32+2)
	LD	B,A
	JR	NC,.NOW_DONE
	INC	B
.NOW_DONE
	POP	IX
	RET

TIME_REPORT
	CALL	TIME_NOW
	LD	DE,(F13_START_TIME)
	OR	A
	SBC	HL,DE
	LD	A,(F13_START_TIME+2)
	LD	E,A
	LD	A,B
	SBC	A,E
	LD	B,A
	JR	NC,.NO_WRAP
	LD	DE,0x5180
	ADD	HL,DE
	LD	A,B
	ADC	A,1
	LD	B,A
.NO_WRAP
	LD	(F13_ELAPSED),HL
	LD	A,B
	LD	(F13_ELAPSED+2),A
	LD	HL,MSG_SUMMARY_PREFIX
	CALL	@CONSOLE.STRING
	LD	HL,(F13_TRANSFERRED)
	LD	DE,(F13_TRANSFERRED+2)
	CALL	PRINT_DEC32
	LD	HL,MSG_SUMMARY_BYTES
	CALL	@CONSOLE.STRING
	LD	HL,(F13_ELAPSED)
	LD	DE,(F13_ELAPSED+2)	; see memory.inc: +3 is structurally zero
	CALL	PRINT_DEC32
	LD	HL,MSG_SUMMARY_SEC
	CALL	@CONSOLE.STRING
	CALL	PRINT_RATE
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

; PRINT_RATE appends ", N KB/s" to the summary line, the same rate WGET
; reports. Whole KB per whole second: the RTC resolves seconds only, so a
; finer unit would claim precision the sample does not have. The rate is
; simply left off when it cannot be stated honestly -- a sample shorter than
; one RTC second, or a transfer whose KB count no longer fits 16 bits.
PRINT_RATE
	LD	A,(F13_ELAPSED+2)
	OR	A
	RET	NZ			; over 18 h: seconds no longer fit BC
	LD	BC,(F13_ELAPSED)
	LD	A,B
	OR	C
	RET	Z			; sub-second sample, as in DLSPEED
	LD	HL,F13_TRANSFERRED
	CALL	KB_OF
	LD	A,E
	OR	A
	RET	NZ			; over 64 MB in one transfer
	; DE is the zero left by KB_OF and becomes the quotient. The loop runs
	; once per whole KB/s, so a few hundred iterations at most; it counts
	; ahead of the subtraction and gives the extra one back on the borrow.
.DIVIDE
	INC	DE
	OR	A
	SBC	HL,BC
	JR	NC,.DIVIDE
	DEC	DE
	LD	HL,MSG_COMMA
	CALL	@CONSOLE.STRING
	EX	DE,HL
	LD	DE,0
	CALL	PRINT_DEC32
	LD	HL,MSG_KBPS
	JP	@CONSOLE.STRING

; ------------------------------------------------------------------
; Exit paths.
; ------------------------------------------------------------------

; PRINT_ERR_HEX: HL=message text (no CRLF). Prints CRLF, the message,
; F13_LAST_ERROR as hex, the plain-language cause when there is one, then
; CRLF. Shared by the *_FAIL handlers that report a TCPX/NETDRV status code.
; The hex code is the verdict; the phrase after it is advice only, and an
; unrecognized status prints no phrase rather than a wrong one.
PRINT_ERR_HEX
	PUSH	HL
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	POP	HL
	CALL	@CONSOLE.STRING
	LD	A,(F13_LAST_ERROR)
	CALL	@CONSOLE.HEX8
	LD	A,(F13_LAST_ERROR)
	CALL	@NETERR.DESCRIBE_TCP
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

TCP_OPEN_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(F13_LAST_ERROR),A
	LD	HL,MSG_TCP_OPEN
	JR	TCP_COMMON_FAIL
TCP_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(F13_LAST_ERROR),A
	LD	HL,MSG_TCP_SEND
	JR	TCP_COMMON_FAIL
REPLY_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(F13_LAST_ERROR),A
	LD	HL,MSG_TCP_RECV
TCP_COMMON_FAIL
	CALL	PRINT_ERR_HEX
	CALL	PRINT_REGS
	JP	NETWORK_PRESERVE

RESOLVE_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	HL,MSG_RESOLVE
	CALL	@CONSOLE.LINE
	JP	NETWORK_PRESERVE
NETWORK_PRESERVE
	CALL	FLUSH_BUFFER_QUIET
	CALL	CLOSE_LOCAL_FILE
	LD	B,DSS_EXIT_NETWORK
	JP	FAIL_EXIT

; REPLY_BAD/PASV_FAIL/REST_REFUSED share one tail: print the message, close
; the control channel, close whatever local file may be open (a harmless
; no-op via CLOSE_LOCAL_FILE's own F13_FILE_OPEN check when there is none),
; and exit DSS_EXIT_REMOTE. REPLY_BAD alone adds a leading CRLF since it can
; be reached mid-line, unlike the other two which always follow PRINT_REPLY.
REPLY_BAD
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_BAD_REPLY
	JR	REMOTE_FAIL_COMMON
PASV_FAIL
	LD	HL,MSG_E_PASV
	JR	REMOTE_FAIL_COMMON
REST_REFUSED
	LD	HL,MSG_E_NO_REST
REMOTE_FAIL_COMMON
	CALL	@CONSOLE.LINE
	; REST_REFUSED and a 5xx answer to RETR/STOR/LIST are both reached with
	; the PASV data channel already established; drop it with an RST instead
	; of walking away and leaving the server a half-open session. ABORT is a
	; no-op on a channel that was never opened (PASV_FAIL's path).
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.ABORT
	XOR	A
	CALL	@TCPX.CLOSE
	CALL	CLOSE_LOCAL_FILE
	LD	B,DSS_EXIT_REMOTE
	JP	FAIL_EXIT

DATA_OPEN_FAIL
	CP	NETDRV_ERR_CANCELLED
	JP	Z,USER_ABORT
	LD	(F13_LAST_ERROR),A
	LD	HL,MSG_E_DATA_OPEN
	CALL	PRINT_ERR_HEX
	XOR	A
	CALL	@TCPX.CLOSE
	CALL	CLOSE_LOCAL_FILE
	LD	B,DSS_EXIT_NETWORK
	JP	FAIL_EXIT

DATA_RX_FAIL
	LD	(F13_LAST_ERROR),A
	CALL	FLUSH_BUFFER_QUIET
	CALL	CLOSE_LOCAL_FILE
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.ABORT
	XOR	A
	CALL	@TCPX.CLOSE
	LD	HL,MSG_E_DATA_RX
	CALL	PRINT_ERR_HEX
	LD	B,DSS_EXIT_NETWORK
	JP	FAIL_EXIT

FILE_FAIL
	CALL	CLOSE_LOCAL_FILE
	LD	HL,MSG_FILE
	CALL	@CONSOLE.LINE
	LD	B,DSS_EXIT_LOCAL
	JP	FAIL_EXIT
CONFIG_FAIL
	LD	B,DSS_EXIT_CONFIG
	JP	FAIL_EXIT
HARDWARE_FAIL
	LD	B,DSS_EXIT_HARDWARE
	JP	FAIL_EXIT
PROMPT_CANCEL
	LD	B,DSS_EXIT_CANCELLED
	JP	EXIT_NO_RESULT
USAGE_FAIL
	LD	HL,MSG_USAGE_ERROR
	CALL	@CONSOLE.LINE
	LD	HL,MSG_HELP
	CALL	@CONSOLE.STRING
	LD	B,DSS_EXIT_ARGUMENT
	JP	FAIL_EXIT

; USER_ABORT keeps whatever GET already wrote (flush + close, resumable with
; -r); PUT and LIST just close/skip. Both data and control channels are
; aborted with a best-effort RST.
USER_ABORT
	LD	A,(F13_FILE_OPEN)
	OR	A
	JR	Z,.NO_FILE
	LD	A,(F13_MODE)
	CP	1
	JR	Z,.CLOSE_ONLY
	CALL	FLUSH_BUFFER
	CALL	PRINT_PROGRESS
.CLOSE_ONLY
	CALL	CLOSE_LOCAL_FILE
.NO_FILE
	LD	A,FTP_DATA_CHANNEL
	CALL	@TCPX.ABORT
	XOR	A
	CALL	@TCPX.ABORT
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_ABORT_TRANSFER
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
	LD	A,(F13_LAST_ERROR)
	CALL	@CONSOLE.HEX8
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

SUCCESS_NO_FILE
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

; Deliberately silent: reached only when the page claim failed, so the stack
; is still in WIN1 -- see wget.asm's BOOT_FAIL for the WIN_MOVE hazard.
BOOT_FAIL
	DSS_RETURN DSS_EXIT_LOCAL

CMD_USER	DB "USER "
CMD_USER_LEN	EQU $ - CMD_USER
CMD_PASS	DB "PASS "
CMD_PASS_LEN	EQU $ - CMD_PASS
CMD_TYPE_I	DB "TYPE I"
CMD_TYPE_I_LEN	EQU $ - CMD_TYPE_I
CMD_PASV	DB "PASV"
CMD_PASV_LEN	EQU $ - CMD_PASV
CMD_QUIT	DB "QUIT"
CMD_QUIT_LEN	EQU $ - CMD_QUIT
CMD_LIST	DB "LIST "
CMD_LIST_LEN	EQU $ - CMD_LIST
CMD_NLST	DB "NLST "
CMD_NLST_LEN	EQU $ - CMD_NLST
CMD_STOR	DB "STOR "
CMD_STOR_LEN	EQU $ - CMD_STOR
CMD_SIZE	DB "SIZE "
CMD_SIZE_LEN	EQU $ - CMD_SIZE
CMD_REST	DB "REST "
CMD_REST_LEN	EQU $ - CMD_REST
CMD_RETR	DB "RETR "
CMD_RETR_LEN	EQU $ - CMD_RETR

MSG_BANNER	DB "3C509B FTP v",PACKAGE_VERSION,0
MSG_RESOLVED	DB "Host ",0
MSG_TO		DB " -> ",0
MSG_PASV_HDR	DB "PASV ",0
MSG_OPENING_DATA DB "Opening data...",0
MSG_DONE_PRE	DB "Done. ",0
MSG_BYTES	DB " bytes recv.",0
MSG_BYTES_SENT	DB " bytes sent.",0
MSG_PROGRESS_MID DB "KB / ",0
MSG_PROGRESS_KB DB "KB",0
MSG_SUMMARY_PREFIX DB "  ",0
MSG_SUMMARY_BYTES DB " bytes in ",0
MSG_SUMMARY_SEC DB " sec",0
MSG_COMMA	DB ", ",0
MSG_KBPS	DB " KB/s",0
MSG_REGS	DB "REGS s=",0
MSG_BASE	DB " b=",0
MSG_STATUS	DB " st=",0
MSG_TCP_OPEN	DB "TCP open fail 0x",0
MSG_TCP_SEND	DB "TCP send fail 0x",0
MSG_TCP_RECV	DB "TCP recv fail 0x",0
MSG_RESOLVE	DB "[E] resolve fail.",0
MSG_BAD_REPLY	DB "[E] bad FTP reply.",0
MSG_E_PASV	DB "[E] bad PASV reply.",0
MSG_E_NO_REST	DB "[E] REST refused, no -r.",0
MSG_NLST_FALLBACK DB "[W] NLST not supported; retrying with LIST.",0
MSG_E_DATA_OPEN DB "[E] data open fail 0x",0
MSG_E_DATA_RX	DB "[E] data recv fail 0x",0
MSG_FILE	DB "[E] file I/O fail.",0
MSG_ABORT_TRANSFER DB "Aborted (Esc/^C).",0
MSG_USAGE_ERROR DB "[E] bad args",0
MSG_HELP
	DB "Usage:",13,10
	DB "  FTP host[:port] path [-u u] [-p p] [-o out] [-y|-f] [-r] [-d]",13,10
	DB "  FTP host[:port] PUT local [-u u] [-p p] [-o remote]",13,10
	DB "  FTP host[:port] [path] -l|-n [-u u] [-p p]",13,10
	DB "  FTP /?",13,10,13,10
	DB "  -u/-p login (default anonymous); -o renames the other side;",13,10
	DB "  -y/-f overwrite; -r resume GET; -d dot progress.",13,10,0
MSG_OK		DB "RESULT OK",13,10,0
MSG_FAIL	DB "RESULT FAIL",13,10,0

; Bottom of the command staging area; see wget.asm for why the exit code
; lives here rather than in the runtime data area.
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
	INCLUDE "file.asm"
	INCLUDE "stage9_cli.asm"
	INCLUDE "tcp_transport.asm"
	INCLUDE "stage11_app.asm"
	INCLUDE "stage12_dns.asm"
	INCLUDE "neterr.asm"

	; The image is code and rodata only and must end where the WIN2 data
	; area starts. For FTP that is 2 KiB past PAGE_BASE (memory.inc).
	ASSERT $ <= S13_IMAGE_LIMIT
