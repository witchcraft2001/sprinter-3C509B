; Plain-language cause for a kit status byte.
; SPDX-License-Identifier: BSD-3-Clause
;
; The kit's status bytes live in one flat space: EL3_ERR_* 1..20 (el3.inc),
; NETDRV_ERR_* 21..29 (netdrv.inc) and TCP_ERR_* 30..36 (tcp.inc). Every app
; already prints that byte as stable hex, which is what a bug report quotes
; and what the acceptance logs match on. This module adds a short phrase in
; brackets after it, so the failures a user can act on -- a closed port, an
; unplugged cable, a gateway that never answers ARP -- read as an answer
; rather than as a number to look up.
;
; The hex code stays the verdict. Nothing here is load-bearing: an unknown
; code prints no phrase at all instead of guessing, and no caller branches on
; what this module printed.

	IFNDEF	_NETERR_ASM
	DEFINE	_NETERR_ASM

	INCLUDE "el3.inc"
	INCLUDE "netdrv.inc"
	INCLUDE "tcp.inc"
	INCLUDE "memory.inc"

	MODULE NETERR

; DESCRIBE_TCP: A = status byte from a TCPX call.
; One status covers several causes depending on where the transport was when
; it gave up, and TCPX already publishes that in S11_DIAG_STAGE: a connect
; timeout in TCP_STAGE_ARP is a local routing problem, the same timeout in
; TCP_STAGE_SYN is a remote host that will not answer, and an RST in
; TCP_STAGE_SYN is a refusal by a host that is up. Those get their own
; wording; everything else falls through to the status-only table.
; In: A = status. Out: -. Clobbers AF, BC, DE, HL. Preserves IX, IY.
; Call with the ISA window closed (this prints through DSS) and the program's
; own page still mapped (S11_DIAG_STAGE lives there).
DESCRIBE_TCP
	LD	HL,S11_DIAG_STAGE
	LD	C,(HL)
	LD	B,A
	LD	HL,STAGED
.SCAN
	LD	A,(HL)
	INC	HL
	OR	A
	JR	Z,DESCRIBE_B		; no staged match: try the plain table
	CP	B
	JR	NZ,.SKIP
	LD	A,(HL)
	CP	C
	JR	Z,.HIT
.SKIP
	INC	HL			; step over the stage byte
.TEXT
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.TEXT
	JR	.SCAN
.HIT
	INC	HL
	JR	EMIT

; DESCRIBE: A = any status byte. Prints " (phrase)" when the code is one of
; the ones below, and prints nothing at all otherwise.
; In: A = status. Out: -. Clobbers AF, BC, DE, HL. Preserves IX, IY.
; Call with the ISA window closed (this prints through DSS).
DESCRIBE
	LD	B,A
DESCRIBE_B
	LD	HL,PLAIN
.SCAN
	LD	A,(HL)
	INC	HL
	OR	A
	RET	Z			; table end: unknown code, stay silent
	CP	B
	JR	Z,EMIT
.SKIP
	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.SKIP
	JR	.SCAN

; EMIT: HL -> the phrase, already past its key bytes.
EMIT
	PUSH	HL
	LD	HL,T_OPEN
	CALL	@CONSOLE.STRING
	POP	HL
	CALL	@CONSOLE.STRING
	LD	HL,T_CLOSE
	JP	@CONSOLE.STRING

T_OPEN		DB " (",0
T_CLOSE		DB ")",0

; status, stage, text. Terminated by a zero status.
STAGED
	DB TCP_ERR_RESET,TCP_STAGE_SYN
	DB "refused, no server on that port",0
	DB TCP_ERR_TIMEOUT,TCP_STAGE_SYN
	DB "no answer from host",0
	DB TCP_ERR_TIMEOUT,TCP_STAGE_ARP
	DB "no ARP reply, check gateway",0
	DB 0

; status, text. Ordered by how often a user meets them: the scan is linear.
PLAIN
	DB TCP_ERR_RESET
	DB "reset by server",0
	DB TCP_ERR_TIMEOUT
	DB "no reply from server",0
	DB TCP_ERR_CLOSED
	DB "server closed the connection",0
	DB EL3_ERR_LINK_TIMEOUT
	DB "no link, check the cable",0
	DB NETDRV_ERR_PROTOCOL
	DB "bad reply from server",0
	DB 0

	ENDMODULE

	ENDIF
