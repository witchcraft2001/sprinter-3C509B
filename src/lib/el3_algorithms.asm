; Pure 3C509B Stage 3 algorithms, shared with z88dk-ticks regressions.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_EL3_ALGORITHMS_ASM
	DEFINE	_EL3_ALGORITHMS_ASM

	INCLUDE "el3.inc"
	INCLUDE "dss.inc"
	INCLUDE "memory.inc"

	MODULE EL3ALG

; VDIAG publishes the VALIDATE check about to run. Only EL3EEP defines
; EL3_VALIDATE_DIAG; everywhere else the macro expands to nothing, so no
; application pays image bytes for the diagnostic. It must not touch flags
; that a following comparison depends on, so it only writes A.
	MACRO VDIAG reason
	IFDEF	EL3_VALIDATE_DIAG
	LD	A,reason
	LD	(EL3_VALIDATE_FAIL),A
	ENDIF
	ENDM

	IFNDEF STAGE12_LAYOUT	; WGET maps its own statuses, and needs the bytes
; TO_DSS_EXIT maps a detailed EL3 status to the common DSS process-exit ABI.
; In: A=detailed EL3 status. Out: B=1 arguments, 2 hardware, 3 timeout/network,
; or 5 local DSS/memory. Clobbers AF and B; preserves DE, HL, IX and IY.
TO_DSS_EXIT
	LD	B,DSS_EXIT_HARDWARE
	OR	A
	JR	Z,.EXIT_OK
	CP	EL3_ERR_USAGE
	JR	Z,.EXIT_ARGUMENT
	CP	EL3_ERR_PARAMETER
	JR	Z,.EXIT_ARGUMENT
	CP	EL3_ERR_TIMER
	JR	Z,.EXIT_TIMEOUT
	CP	EL3_ERR_CMD_TIMEOUT
	JR	Z,.EXIT_TIMEOUT
	CP	EL3_ERR_TX_TIMEOUT
	JR	Z,.EXIT_TIMEOUT
	CP	EL3_ERR_RX_TIMEOUT
	JR	Z,.EXIT_TIMEOUT
	CP	EL3_ERR_LINK_TIMEOUT
	JR	Z,.EXIT_TIMEOUT
	CP	EL3_ERR_NO_MEMORY
	JR	Z,.EXIT_LOCAL
	RET
.EXIT_OK
	LD	B,DSS_EXIT_OK
	RET
.EXIT_ARGUMENT
	LD	B,DSS_EXIT_ARGUMENT
	RET
.EXIT_TIMEOUT
	LD	B,DSS_EXIT_NETWORK
	RET
.EXIT_LOCAL
	LD	B,DSS_EXIT_LOCAL
	RET
	ENDIF

; LFSR_NEXT
; In: A = current activation byte. Out: A = next byte.
; Preserves BC, DE, HL, IX and IY.
LFSR_NEXT
	ADD	A,A
	RET	NC
	XOR	EL3_LFSR_POLY
	RET

; BASE_DECODE: only ACTIVATE's EEPROM-base branch calls this, and that
; branch is unreachable for UNET_DLL (see el3.asm's own comment on why).
	IFNDEF	UNET_DLL
; In: A = base index 00..1E. Out: HL = 0200..03E0, CF=0.
; Invalid index returns EL3_ERR_BASE and CF=1.
; Preserves BC, DE, IX and IY.
BASE_DECODE
	CP	EL3_BASE_COUNT
	JR	NC,.BAD
	LD	L,A
	LD	H,0
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,HL
	LD	DE,EL3_BASE_MIN
	ADD	HL,DE
	OR	A
	RET
.BAD
	LD	A,EL3_ERR_BASE
	SCF
	RET
	ENDIF

; BASE_ENCODE
; In: HL = 0200..03E0 aligned to 10h. Out: A = index 00..1E, CF=0.
; Preserves BC, DE, HL, IX and IY.
BASE_ENCODE
	PUSH	HL
	LD	A,L
	AND	0x0F
	JR	NZ,.BAD_POP
	OR	A
	LD	DE,EL3_BASE_MIN
	SBC	HL,DE
	JR	C,.BAD_POP
	LD	DE,EL3_BASE_MAX-EL3_BASE_MIN
	EX	DE,HL
	OR	A
	SBC	HL,DE
	JR	C,.BAD_POP
.RANGE_OK
	EX	DE,HL
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	LD	B,A
	LD	A,H
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0x10
	OR	B
	POP	HL
	OR	A
	RET
.BAD_POP
	POP	HL
	LD	A,EL3_ERR_BASE
	SCF
	RET

; COPY_MAC
; Copies the factory station address to EL3_MAC in network order.
; In the 3Com layout a word holds Address(2n) in its high byte and Address(2n+1)
; in its low byte, so the little-endian buffer has every pair reversed and the
; bytes have to be swapped back. A physical 3C509B-TPO labelled EA=0020AF5D698B
; reads 0020 AF5D 698B in words 00..02, which settles the order; the project's
; synthetic images were built to the opposite convention and agreed with
; themselves, so nothing local could show it.
; VALIDATE is the only caller. It has already saved BC, DE, HL, IX and IY and
; sets A itself, so this preserves nothing.
COPY_MAC
	LD	HL,EEPROM_BUFFER + 1
	LD	DE,EL3_MAC
	LD	B,3
.LOOP
	LD	A,(HL)
	LD	(DE),A
	DEC	HL
	INC	DE
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	HL
	INC	HL
	INC	DE
	DJNZ	.LOOP
	RET

; VALIDATE
; Validates exact IDs, unicast MAC, and both documented checksum lanes.
; Out: A=EL3_OK/CF=0 or stable error/CF=1.
; Preserves BC, DE, HL, IX and IY.
VALIDATE
	PUSH	BC,DE,HL,IX,IY
	VDIAG	EL3_VFAIL_PRODUCT
	LD	HL,(EEPROM_BUFFER + 0x03*2)
	LD	DE,EL3_PRODUCT_3C509B_TPO
	OR	A
	SBC	HL,DE
	JR	NZ,.NOT_FOUND
	VDIAG	EL3_VFAIL_MFG
	LD	HL,(EEPROM_BUFFER + 0x07*2)
	LD	DE,EL3_MFG_3COM
	OR	A
	SBC	HL,DE
	JR	NZ,.NOT_FOUND
	VDIAG	EL3_VFAIL_MAC
	CALL	VALIDATE_MAC
	JR	C,.RETURN
	VDIAG	EL3_VFAIL_PRIMARY
	CALL	VALIDATE_PRIMARY
	JR	C,.RETURN
	VDIAG	EL3_VFAIL_SECONDARY
	CALL	VALIDATE_SECONDARY
	JR	C,.RETURN
	CALL	COPY_MAC
	VDIAG	EL3_VFAIL_NONE
	XOR	A
.RETURN
	POP	IY,IX,HL,DE,BC
	RET
.NOT_FOUND
	LD	A,EL3_ERR_NOT_FOUND
	SCF
	JR	.RETURN

; VALIDATE_MAC
; Out: EL3_OK or EL3_ERR_NOT_FOUND. Preserves BC, DE, HL, IX and IY.
VALIDATE_MAC
	PUSH	BC,DE,HL,IX,IY
	LD	HL,EEPROM_BUFFER
	INC	HL			; the group bit lives in Address(0), the
	BIT	0,(HL)			; high byte of word 00
	JR	NZ,.BAD
	DEC	HL
	LD	B,6
	LD	C,0
	LD	D,0xFF
.LOOP
	LD	A,(HL)
	LD	E,A
	OR	C
	LD	C,A
	LD	A,E
	AND	D
	LD	D,A
	INC	HL
	DJNZ	.LOOP
	LD	A,C
	OR	A
	JR	Z,.BAD
	LD	A,D
	CP	0xFF
	JR	Z,.BAD
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD
	LD	A,EL3_ERR_NOT_FOUND
	SCF
	POP	IY,IX,HL,DE,BC
	RET

; VALIDATE_PRIMARY
; Checksum word 0F high lane covers 00..0E except 08/09/0D; low lane covers
; only 08/09/0D. Both bytes of each selected word are XORed.
VALIDATE_PRIMARY
	PUSH	BC,DE,HL,IX,IY
	LD	HL,EEPROM_BUFFER
	LD	B,15
	LD	C,0
	LD	D,0
	LD	E,0
.LOOP
	LD	A,C
	CP	0x08
	JR	Z,.CONFIG
	CP	0x09
	JR	Z,.CONFIG
	CP	0x0D
	JR	Z,.CONFIG
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	LD	A,(HL)
	XOR	D
	LD	D,A
	JR	.NEXT
.CONFIG
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	LD	A,(HL)
	XOR	E
	LD	E,A
.NEXT
	INC	HL
	INC	C
	DJNZ	.LOOP
	IFDEF	EL3_VALIDATE_DIAG
	LD	A,E
	LD	(EL3_PRIMARY_CALC),A
	LD	A,D
	LD	(EL3_PRIMARY_CALC+1),A
	ENDIF
	LD	A,(EEPROM_BUFFER + 0x0F*2 + 1)
	CP	D
	JR	NZ,.BAD
	LD	A,(EEPROM_BUFFER + 0x0F*2)
	CP	E
	JR	NZ,.BAD
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD
	LD	A,EL3_ERR_CHECKSUM
	SCF
	POP	IY,IX,HL,DE,BC
	RET

; VALIDATE_SECONDARY
; The two lanes of word 17 partition the whole 10..3F range: the configurable
; lane is exactly 13..16, the vital lane is everything else except word 17
; itself, so 10..12 and 18..3F. An earlier reading of the documentation had the
; vital lane start at 20; a physical 3C509B-TPO (assembly 03-0020-002 rev 3,
; MAC 00:20:AF:5D:69:8B) stores 0205 in word 17 and that lane assignment
; computed 1305 for it, differing by exactly the XOR of words 18..1F. The
; project's own synthetic images could not expose this: their words 18..1F are
; zero, which leaves both readings identical.
VALIDATE_SECONDARY
	PUSH	BC,DE,HL,IX,IY
	LD	D,0
	LD	E,0
	LD	HL,EEPROM_BUFFER + 0x10*2
	LD	B,3
	CALL	XOR_WORD_BYTES_D
	LD	HL,EEPROM_BUFFER + 0x18*2
	LD	B,40
	CALL	XOR_WORD_BYTES_D
	LD	HL,EEPROM_BUFFER + 0x13*2
	LD	B,4
	CALL	XOR_WORD_BYTES_E
	IFDEF	EL3_VALIDATE_DIAG
	LD	A,E
	LD	(EL3_SECONDARY_CALC),A
	LD	A,D
	LD	(EL3_SECONDARY_CALC+1),A
	ENDIF
	LD	A,(EEPROM_BUFFER + 0x17*2 + 1)
	CP	D
	JR	NZ,.BAD
	LD	A,(EEPROM_BUFFER + 0x17*2)
	CP	E
	JR	NZ,.BAD
	XOR	A
	POP	IY,IX,HL,DE,BC
	RET
.BAD
	LD	A,EL3_ERR_CHECKSUM
	SCF
	POP	IY,IX,HL,DE,BC
	RET

XOR_WORD_BYTES_D
.LOOP
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	DJNZ	.LOOP
	RET

XOR_WORD_BYTES_E
.LOOP
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	DJNZ	.LOOP
	RET

	ENDMODULE
	ENDIF
