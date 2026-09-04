; Safe Sprinter ISA8 window access.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_ISA_ASM
	DEFINE	_ISA_ASM

	INCLUDE "sprinter.inc"
	INCLUDE "isa.inc"

	MODULE ISA

; OPEN
; In:  A = slot (0 or 1).
; Out: CF=0, A=ISA_OK; CF=1 with explicit status otherwise.
; Preserves BC, DE, HL, IX and IY. Interrupts remain disabled until CLOSE.
OPEN
	PUSH	BC,DE,HL,IX,IY
	LD	D,A
	CP	2
	JR	NC,.BAD_SLOT
	LD	A,(IS_OPEN)
	OR	A
	JR	NZ,.STATE_ERROR
	; Sample IFF2 before DI clears it. A maskable interrupt accepted
	; during LD A,I clears P/V regardless of IFF2 (documented Z80
	; erratum); that interrupt has already been serviced and its handler
	; returns with interrupts enabled, so a second read observes IFF2
	; correctly. Sampling once would record "was disabled" and CLOSE
	; would then skip its EI, leaving DSS without timer and keyboard for
	; the rest of the run.
	LD	A,I
	JP	PE,.IFF_ON
	LD	A,I
	JP	PE,.IFF_ON
	XOR	A
	JR	.IFF_SAVED
.IFF_ON
	LD	A,1
.IFF_SAVED
	DI
	LD	(IFF_WAS_ENABLED),A
	LD	BC,PAGE3
	IN	A,(C)
	LD	(SAVED_MMU3),A
	LD	BC,PORT_SYSTEM
	LD	A,0x11
	OUT	(C),A
	LD	A,D
	SLA	A
	OR	0xD4
	LD	BC,PAGE3
	OUT	(C),A
	LD	BC,PORT_ISA
	XOR	A
	OUT	(C),A
	LD	A,1
	LD	(IS_OPEN),A
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD_SLOT
	LD	A,ISA_ERR_STATE
	SCF
	POP	IY,IX,HL,DE,BC
	RET
.STATE_ERROR
	LD	A,ISA_ERR_STATE
	SCF
	POP	IY,IX,HL,DE,BC
	RET

; CLOSE
; Out: CF=0, A=ISA_OK. Restores MMU3 and the entry interrupt state.
; Preserves BC, DE, HL, IX and IY.
CLOSE
	PUSH	BC,DE,HL,IX,IY
	LD	A,(IS_OPEN)
	OR	A
	JR	Z,.STATE_ERROR
	LD	BC,PORT_SYSTEM
	LD	A,0x01
	OUT	(C),A
	LD	A,(SAVED_MMU3)
	LD	BC,PAGE3
	OUT	(C),A
	XOR	A
	LD	(IS_OPEN),A
	LD	A,(IFF_WAS_ENABLED)
	OR	A
	JR	Z,.KEEP_DISABLED
	EI
.KEEP_DISABLED
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.STATE_ERROR
	LD	A,ISA_ERR_STATE
	SCF
	POP	IY,IX,HL,DE,BC
	RET

; MAP_POINTER
; In: BC = 14-bit ISA I/O address. Out: HL = ISA window address.
; Preserves BC, DE, IX and IY.
MAP_POINTER
	LD	H,B
	SET	6,H
	SET	7,H
	LD	L,C
	RET

	IFNDEF STAGE12_LAYOUT	; EL3IO uses its own burst path; WGET needs the bytes
; READ8
; In: A = slot, BC = port. Out: A = byte, CF=0; explicit status on failure.
; Preserves BC, DE, HL, IX and IY.
READ8
	CALL	OPEN
	RET	C
	CALL	MAP_POINTER
	LD	A,(HL)
	LD	(READ_VALUE),A
	CALL	CLOSE
	RET	C
	LD	A,(READ_VALUE)
	OR	A
	RET
	ENDIF

; WRITE8
; In: D = slot, BC = port, A = byte. Out: status in A/CF.
; Preserves BC, DE, HL, IX and IY.
WRITE8
	LD	(WRITE_VALUE),A
	LD	A,D
	CALL	OPEN
	RET	C
	CALL	MAP_POINTER
	LD	A,(WRITE_VALUE)
	LD	(HL),A
	CALL	CLOSE
	RET

SAVED_MMU3	DB 0
IFF_WAS_ENABLED	DB 0
IS_OPEN		DB 0
READ_VALUE	DB 0
WRITE_VALUE	DB 0

	ENDMODULE
	ENDIF
