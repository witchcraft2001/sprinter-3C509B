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
; Handles odd lengths. Clobbers AF/BC/DE; preserves IX/IY.
CHECKSUM
	PUSH	IX,IY
	LD	DE,0
	CALL	ACCUMULATE
	LD	A,D
	CPL
	LD	H,A
	LD	A,E
	CPL
	LD	L,A
	POP	IY,IX
	RET

; VERIFY_CHECKSUM succeeds when a complete header sums to FFFFh.
VERIFY_CHECKSUM
	PUSH	IX,IY
	CALL	CHECKSUM
	LD	A,H
	OR	L
	JR	NZ,VERIFY_BAD
	XOR	A
	POP	IY,IX
	RET
VERIFY_BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET

; UDP_IPV4_CHECKSUM
; In: HL=20-byte IPv4 header (no options), BC=UDP length. Returns checksum in
; HL. The UDP checksum field must be zero while building; with a received
; checksum included, a valid datagram returns 0000h. Preserves IX/IY.
UDP_IPV4_CHECKSUM
	PUSH	IX,IY
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
	POP	IY,IX
	RET

; In: HL=data, BC=len, DE=ones-complement accumulator. Out: DE updated.
ACCUMULATE
	PUSH	HL
	POP	IX
.ACC_LOOP
	LD	A,B
	OR	C
	RET	Z
	LD	H,(IX+0)
	INC	IX
	DEC	BC
	LD	A,B
	OR	C
	JR	Z,.ACC_ODD
	LD	L,(IX+0)
	INC	IX
	DEC	BC
	JR	.ACC_ADD
.ACC_ODD
	LD	L,0
.ACC_ADD
	ADD	HL,DE
	EX	DE,HL
	JR	NC,.ACC_LOOP
	INC	DE
	JR	.ACC_LOOP

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
