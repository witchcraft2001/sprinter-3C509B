; Small backend-independent Ethernet/IPv4/UDP primitives used by Stage 7.
; Adapted from the BSD-3-Clause sprinter-rtl8019a transport; hardware access
; and the RTL memory map have deliberately not been carried over.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_ETHERNET_ASM
	DEFINE	_ETHERNET_ASM

	MODULE ETHERNET

ETH_HEADER_LENGTH	EQU 14
ETH_TYPE_IPV4		EQU 0x0800
ETH_TYPE_ARP		EQU 0x0806
IPV4_HEADER_LENGTH	EQU 20
IP_PROTO_UDP		EQU 17

; CHECKSUM
; In: HL=bytes, BC=length. Out: HL=Internet checksum, H is first wire byte.
; Handles odd lengths. Clobbers AF/BC/DE; preserves IX/IY, which since
; ACCUMULATE stopped walking its input through IX costs no save/restore here.
CHECKSUM
	LD	DE,0
	CALL	ACCUMULATE
	LD	A,D
	CPL
	LD	H,A
	LD	A,E
	CPL
	LD	L,A
	RET

; VERIFY_CHECKSUM succeeds when a complete header sums to FFFFh.
VERIFY_CHECKSUM
	CALL	CHECKSUM
	LD	A,H
	OR	L
	JR	NZ,VERIFY_BAD
	XOR	A
	RET
VERIFY_BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

; UDP_IPV4_CHECKSUM
; In: HL=20-byte IPv4 header (no options), BC=UDP length. Returns checksum in
; HL. The UDP checksum field must be zero while building; with a received
; checksum included, a valid datagram returns 0000h. Preserves IX/IY for free,
; as ACCUMULATE no longer walks its input through IX.
UDP_IPV4_CHECKSUM
	LD	(UDP_IP_PTR),HL
	LD	(UDP_LENGTH),BC
	LD	DE,0
	LD	BC,12
	ADD	HL,BC
	LD	BC,8
	CALL	ACCUMULATE
	; Pseudo-header word 00/protocol and UDP length in network numeric order.
	LD	HL,IP_PROTO_UDP
	ADD	HL,DE
	EX	DE,HL
	JR	NC,.NO_CARRY1
	INC	DE
.NO_CARRY1
	LD	HL,(UDP_LENGTH)
	ADD	HL,DE
	EX	DE,HL
	JR	NC,.NO_CARRY2
	INC	DE
.NO_CARRY2
	LD	HL,(UDP_IP_PTR)
	LD	BC,IPV4_HEADER_LENGTH
	ADD	HL,BC
	LD	BC,(UDP_LENGTH)
	CALL	ACCUMULATE
	LD	A,D
	CPL
	LD	H,A
	LD	A,E
	CPL
	LD	L,A
	RET

; In: HL=data, BC=len, DE=ones-complement accumulator. Out: DE updated.
; Clobbers AF, BC and HL; unlike the earlier (IX+0) walk it leaves IX intact.
;
; The running sum lives in HL and the source in DE, so a byte costs
; LD A,(DE)/ADC A,r/LD r,A/INC DE -- 21 T where indexed loads cost 66 T. The
; carry has to ripple across the whole buffer, so the loop control is built
; only from instructions that leave CF alone: DJNZ, INC DE and 8-bit DEC.
; Each word adds its low half first, which is what makes the carry out of one
; word land in the next word's bit 0 -- the end-around carry of RFC 1071 --
; rather than in its bit 8. That costs nothing but means HL holds the
; byte-swapped sum while the loop runs, so the halves are exchanged on entry
; and again on exit.
ACCUMULATE
	LD	A,B
	OR	C
	RET	Z
	LD	A,C
	AND	1
	LD	(ACC_ODD),A		; a trailing byte pads as the high half
	SRL	B
	RR	C			; BC = whole 16-bit words
	IFDEF FAST_DATAPATH
	; Four words per DJNZ pass instead of one. The split is computed here,
	; before the OR A below arms the ripple, because SRL/RR write CF: once
	; the ripple is live nothing may touch the carry, which is also why the
	; tail count is re-tested with INC B/DEC B rather than OR A further
	; down.
	LD	A,C
	AND	3
	LD	(ACC_TAIL_WORDS),A	; 0..3 words left over after the groups
	SRL	B
	RR	C
	SRL	B
	RR	C			; BC = whole four-word groups
	ENDIF
	EX	DE,HL			; HL = accumulator, DE = source
	LD	A,H
	LD	H,L
	LD	L,A			; enter the byte-swapped domain
	OR	A			; CF = 0 before the ripple starts
	LD	A,B
	OR	C
	JR	Z,.ACC_AFTER_GROUPS
	LD	A,B			; DJNZ counts in B, so run the low half
	LD	B,C			; inline and the high half as outer passes
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.ACC_WORDS
	INC	C
.ACC_WORDS
	IFDEF FAST_DATAPATH
	DUP 4
	LD	A,(DE)
	ADC	A,L
	LD	L,A
	INC	DE
	LD	A,(DE)
	ADC	A,H
	LD	H,A
	INC	DE
	EDUP
	ELSE
	LD	A,(DE)
	ADC	A,L
	LD	L,A
	INC	DE
	LD	A,(DE)
	ADC	A,H
	LD	H,A
	INC	DE
	ENDIF
	DJNZ	.ACC_WORDS
	DEC	C
	JR	NZ,.ACC_WORDS
.ACC_AFTER_GROUPS
	IFDEF FAST_DATAPATH
	LD	A,(ACC_TAIL_WORDS)
	LD	B,A
	INC	B
	DEC	B			; Z iff no tail words; leaves CF alone
	JR	Z,.ACC_TAIL
.ACC_TAIL_LOOP
	LD	A,(DE)
	ADC	A,L
	LD	L,A
	INC	DE
	LD	A,(DE)
	ADC	A,H
	LD	H,A
	INC	DE
	DJNZ	.ACC_TAIL_LOOP
	ENDIF
.ACC_TAIL
	LD	A,(ACC_ODD)
	BIT	0,A			; BIT, not OR: the ripple carry is still live
	JR	Z,.ACC_FOLD
	LD	A,(DE)
	ADC	A,L
	LD	L,A
	LD	A,0			; not XOR A, which would drop the carry
	ADC	A,H
	LD	H,A
.ACC_FOLD
	LD	BC,0
	ADC	HL,BC			; fold the end-around carry once...
	JR	NC,.ACC_DONE
	INC	HL			; ...and again if FFFFh wrapped to zero
.ACC_DONE
	LD	A,H
	LD	H,L
	LD	L,A
	EX	DE,HL
	RET

ACC_ODD		DB 0
	IFDEF FAST_DATAPATH
ACC_TAIL_WORDS	DB 0		; words the four-word group loop did not cover
	ENDIF

; WRITE_BE16: HL=value, DE=destination. Advances DE by two.
WRITE_BE16
	LD	A,H
	LD	(DE),A
	INC	DE
	LD	A,L
	LD	(DE),A
	INC	DE
	RET

; READ_BE16: HL=source. Returns DE=value and advances HL by two.
READ_BE16
	LD	D,(HL)
	INC	HL
	LD	E,(HL)
	INC	HL
	RET

UDP_IP_PTR	DW 0
UDP_LENGTH	DW 0

	ENDMODULE
	ENDIF
