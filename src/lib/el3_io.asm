; Physical Sprinter ISA8 provider for the EL3 register core.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_EL3_IO_ASM
	DEFINE	_EL3_IO_ASM

	INCLUDE "el3.inc"
	INCLUDE "memory.inc"

	MODULE EL3IO

; READ8
; In: E=register offset. Out: A=value/CF=0 or explicit status/CF=1.
; Preserves BC, DE, HL, IX and IY. The ISA window is closed on return.
READ8
	PUSH	BC,DE,HL,IX,IY
	LD	A,E
	CP	0x10
	JR	NC,.BAD_READ
	CALL	OPEN_REGISTER
	JR	C,.READ_ERROR
	LD	A,(HL)
	LD	(READ_VALUE),A
	CALL	@ISA.CLOSE
	JR	C,.READ_ERROR
	LD	A,(READ_VALUE)
	OR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD_READ
	LD	A,EL3_ERR_PARAMETER
	SCF
.READ_ERROR
	POP	IY,IX,HL,DE,BC
	RET

; WRITE8
; In: E=register offset, A=value. Out: status in A/CF.
; Preserves BC, DE, HL, IX and IY. The ISA window is closed on return.
WRITE8
	PUSH	BC,DE,HL,IX,IY
	LD	(WRITE_VALUE),A
	LD	A,E
	CP	0x10
	JR	NC,.BAD_WRITE
	CALL	OPEN_REGISTER
	JR	C,.WRITE_ERROR
	LD	A,(WRITE_VALUE)
	LD	(HL),A
	CALL	@ISA.CLOSE
	JR	C,.WRITE_ERROR
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD_WRITE
	LD	A,EL3_ERR_PARAMETER
	SCF
.WRITE_ERROR
	POP	IY,IX,HL,DE,BC
	RET

; READ16
; In: E=even register offset. Out: HL=word/CF=0 or explicit status/CF=1.
; The low byte is read immediately before the high byte in one ISA window.
; Preserves BC, DE, IX and IY.
READ16
	PUSH	BC,DE,IX,IY
	LD	A,E
	AND	1
	JR	NZ,.BAD_READ16
	LD	A,E
	CP	0x0F
	JR	NC,.BAD_READ16
	CALL	OPEN_REGISTER
	JR	C,.READ16_ERROR
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	CALL	@ISA.CLOSE
	JR	C,.READ16_ERROR
	EX	DE,HL
	XOR	A
	POP	IY,IX,DE,BC
	RET
.BAD_READ16
	LD	A,EL3_ERR_PARAMETER
	SCF
.READ16_ERROR
	POP	IY,IX,DE,BC
	RET

; WRITE16
; In: E=even register offset, HL=word. Out: status in A/CF.
; The low byte is written immediately before the high byte in one ISA window.
; Preserves BC, DE, HL, IX and IY.
WRITE16
	PUSH	BC,DE,HL,IX,IY
	LD	(WRITE_WORD),HL
	LD	A,E
	AND	1
	JR	NZ,.BAD_WRITE16
	LD	A,E
	CP	0x0F
	JR	NC,.BAD_WRITE16
	CALL	OPEN_REGISTER
	JR	C,.WRITE16_ERROR
	LD	DE,(WRITE_WORD)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	CALL	@ISA.CLOSE
	JR	C,.WRITE16_ERROR
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD_WRITE16
	LD	A,EL3_ERR_PARAMETER
	SCF
.WRITE16_ERROR
	POP	IY,IX,HL,DE,BC
	RET

; FIFO_WRITE / FIFO_ZERO / FIFO_READ / FIFO_SKIP
; Byte streams use only Window 1/base+00. Each burst owns one short ISA
; critical section and closes the ISA window on every return.
; FIFO_WRITE: HL=source, BC=count. FIFO_ZERO: BC=count.
; FIFO_READ: HL=destination, BC=count. FIFO_SKIP: BC=count.
; All return A=EL3_OK/CF=0 or explicit error/CF=1, clobber AF only and
; preserve BC, DE, HL, IX and IY.
FIFO_WRITE
	PUSH	BC,DE,HL,IX,IY
	CALL	OPEN_FIFO
	JR	C,.FIFO_WRITE_ERROR
.FIFO_WRITE_LOOP
	LD	A,B
	OR	C
	JR	Z,.FIFO_WRITE_CLOSE
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	DEC	BC
	JR	.FIFO_WRITE_LOOP
.FIFO_WRITE_CLOSE
	CALL	@ISA.CLOSE
.FIFO_WRITE_ERROR
	POP	IY,IX,HL,DE,BC
	RET

FIFO_ZERO
	PUSH	BC,DE,HL,IX,IY
	CALL	OPEN_FIFO
	JR	C,.FIFO_ZERO_ERROR
	XOR	A
.FIFO_ZERO_LOOP
	LD	D,A
	LD	A,B
	OR	C
	LD	A,D
	JR	Z,.FIFO_ZERO_CLOSE
	LD	(HL),A
	DEC	BC
	JR	.FIFO_ZERO_LOOP
.FIFO_ZERO_CLOSE
	CALL	@ISA.CLOSE
.FIFO_ZERO_ERROR
	POP	IY,IX,HL,DE,BC
	RET

; FIFO_READ moves a whole received packet, so its inner loop is the one worth
; tightening: DJNZ against a fixed port pointer costs 33 T/byte where the
; counted 16-bit loop cost 53, shortening the copy and the DI window around it
; by the same margin. DJNZ only counts in B, so the high half of the count runs
; as outer passes. Unrolling four bytes per pass would buy another 10 T/byte,
; but the WGET image has no room for it (S10_BOOTSTRAP_STACK_RESERVE,
; memory.inc). The other three bursts stay counted: on a download FIFO_WRITE
; only sends ACK-sized bursts, and FIFO_ZERO/FIFO_SKIP move at most three
; padding bytes.
FIFO_READ
	PUSH	BC,DE,HL,IX,IY
	CALL	OPEN_FIFO
	JR	C,.FIFO_READ_ERROR
	; HL = fixed data port, DE = destination, BC = count.
	LD	A,B
	OR	C
	JR	Z,.FIFO_READ_CLOSE
	LD	A,B
	LD	B,C
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.FIFO_READ_LOOP
	INC	C
.FIFO_READ_LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.FIFO_READ_LOOP
	DEC	C
	JR	NZ,.FIFO_READ_LOOP
.FIFO_READ_CLOSE
	CALL	@ISA.CLOSE
.FIFO_READ_ERROR
	POP	IY,IX,HL,DE,BC
	RET

FIFO_SKIP
	PUSH	BC,DE,HL,IX,IY
	CALL	OPEN_FIFO
	JR	C,.FIFO_SKIP_ERROR
.FIFO_SKIP_LOOP
	LD	A,B
	OR	C
	JR	Z,.FIFO_SKIP_CLOSE
	LD	A,(HL)
	DEC	BC
	JR	.FIFO_SKIP_LOOP
.FIFO_SKIP_CLOSE
	CALL	@ISA.CLOSE
.FIFO_SKIP_ERROR
	POP	IY,IX,HL,DE,BC
	RET

OPEN_FIFO
	PUSH	BC
	LD	D,H
	LD	E,L
	LD	A,(@EL3.SLOT)
	CALL	@ISA.OPEN
	JR	C,.FIFO_ISA_ERROR
	LD	BC,(EL3_BASE)
	CALL	@ISA.MAP_POINTER
	POP	BC
	XOR	A
	RET
.FIFO_ISA_ERROR
	POP	BC
	LD	A,EL3_ERR_ISA_STATE
	SCF
	RET
; OPEN_REGISTER
; In: E=offset. Out: HL=mapped address with the ISA window open.
OPEN_REGISTER
	LD	A,(@EL3.SLOT)
	CALL	@ISA.OPEN
	JR	C,.ISA_ERROR
	LD	BC,(EL3_BASE)
	LD	A,C
	ADD	A,E
	LD	C,A
	JR	NC,.MAP
	INC	B
.MAP
	CALL	@ISA.MAP_POINTER
	XOR	A
	RET
.ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	RET

READ_VALUE	DB 0
WRITE_VALUE	DB 0
WRITE_WORD	DW 0

	ENDMODULE
	ENDIF
