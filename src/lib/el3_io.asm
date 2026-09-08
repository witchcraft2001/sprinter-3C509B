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
; TX_BURST replaces the FIFO_WRITE/FIFO_ZERO pair on a whole-frame send, so
; under EL3_SESSION_RX their only caller (@EL3.TX_WRITE_PACKET) is compiled
; out and these two go with it. The source stays put either way: they are
; check-stage5.pl provider anchors.
	IFNDEF	EL3_SESSION_RX
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
	ENDIF

; FIFO_READ moves a whole received packet, so its inner loop is the one worth
; tightening: DJNZ against a fixed port pointer costs 33 T/byte where the
; counted 16-bit loop cost 53, shortening the copy and the DI window around it
; by the same margin. DJNZ only counts in B, so the high half of the count runs
; as outer passes. The other three bursts stay counted: on a download
; FIFO_WRITE only sends ACK-sized bursts, and FIFO_ZERO/FIFO_SKIP move at most
; three padding bytes.
;
; FAST_DATAPATH unrolls eight bytes per DJNZ pass, which drops the loop to
; 21.6 T/byte. It matters more than that arithmetic suggests: on a Sprinter in
; 21 MHz turbo every memory access, opcode fetches included, is stretched to
; the ~3.5 MHz bus slot, so removing four of the seven accesses each byte used
; to make is the real saving. It costs about fifty bytes of image, which is
; why it is a define rather than the default -- FTP.EXE has no room for it,
; WGET.EXE and DLSPEED.EXE do.
FIFO_READ
	PUSH	BC,DE,HL,IX,IY
	CALL	OPEN_FIFO
	JR	C,.FIFO_READ_ERROR
	; HL = fixed data port, DE = destination, BC = count.
	LD	A,B
	OR	C
	JR	Z,.FIFO_READ_CLOSE
	IFDEF FAST_DATAPATH
	LD	A,C
	AND	7
	LD	(FIFO_TAIL),A		; 0..7 bytes left over after the groups
	SRL	B
	RR	C
	SRL	B
	RR	C
	SRL	B
	RR	C			; BC = whole eight-byte groups
	LD	A,B
	OR	C
	JR	Z,.FIFO_READ_TAIL
	LD	A,B
	LD	B,C
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.FIFO_READ_GROUP
	INC	C
.FIFO_READ_GROUP
	DUP 8
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	EDUP
	DJNZ	.FIFO_READ_GROUP
	DEC	C
	JR	NZ,.FIFO_READ_GROUP
.FIFO_READ_TAIL
	LD	A,(FIFO_TAIL)
	OR	A
	JR	Z,.FIFO_READ_CLOSE
	LD	B,A
	ELSE
	LD	A,B
	LD	B,C
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.FIFO_READ_LOOP
	INC	C
	ENDIF
.FIFO_READ_LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.FIFO_READ_LOOP
	IFNDEF FAST_DATAPATH
	DEC	C
	JR	NZ,.FIFO_READ_LOOP
	ENDIF
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

	IFDEF	EL3_SESSION_RX
; RX_COPY_PLAIN
; Bare fixed-port FIFO copy with no ISA open/close of its own: the caller
; (RX_BEGIN/RX_PAYLOAD below) already holds one open session across several
; register/FIFO steps, which is the whole point of EL3_SESSION_RX -- unlike
; FIFO_READ above, which owns a session per call.
; In: HL=mapped FIFO port (e.g. from OPEN_FIFO's own mapping), DE=destination,
; BC=count. Out: DE advanced by count bytes copied. Clobbers AF, BC; leaves
; HL pointed at the fixed port; preserves IX and IY.
RX_COPY_PLAIN
	LD	A,B
	OR	C
	RET	Z
	LD	A,C
	AND	7
	LD	(RXC_TAIL),A		; 0..7 bytes left over after the groups
	SRL	B
	RR	C
	SRL	B
	RR	C
	SRL	B
	RR	C			; BC = whole eight-byte groups
	LD	A,B
	OR	C
	JR	Z,.COPY_TAIL
	LD	A,B
	LD	B,C
	LD	C,A
	LD	A,B
	OR	A
	JR	Z,.COPY_GROUP
	INC	C
.COPY_GROUP
	DUP 8
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	EDUP
	DJNZ	.COPY_GROUP
	DEC	C
	JR	NZ,.COPY_GROUP
.COPY_TAIL
	LD	A,(RXC_TAIL)
	OR	A
	RET	Z
	LD	B,A
.COPY_TAIL_LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	DJNZ	.COPY_TAIL_LOOP
	RET

; RX_COPY_SUM
; Same bare fixed-port FIFO copy as RX_COPY_PLAIN, but accumulating the
; RFC 1071 ones-complement sum of the bytes in the very same pass. This is the
; point of the two-phase receive: a TCP payload gets checksummed while it
; crosses the ISA window, instead of in a second walk over RAM afterwards.
; The accumulator has to live in BC -- HL is pinned to the fixed FIFO port and
; DE to the destination -- so the loop counters go to the shadow B'/C' via
; EXX. DJNZ, DEC, INC rr and EXX all leave CF alone, which matters: CF is the
; live end-around ripple from the first ADC until the fold at the end, and
; nothing between them may touch it (hence INC B/DEC B instead of OR A for the
; zero tests, and LD A,0 instead of XOR A for the odd byte).
; Orientation and fold are @ETHERNET.ACCUMULATE's, byte for byte, so a seed
; from ACCUMULATE and the result here compose in either order.
; In: HL=mapped FIFO port, DE=destination, BC=count 1..2040 (the group count
;     is kept in a single 8-bit shadow register, so larger counts would lose
;     their high byte -- callers pass at most TCP_MSS), (RXS_SUM)=seed.
; Out: (RXS_SUM)=accumulator, DE advanced by count. Clobbers AF, BC, HL and
; the shadow BC; preserves IX and IY.
RX_COPY_SUM
	LD	A,C
	AND	1
	LD	(RXC_ODD),A		; a trailing byte pads as the high half
	SRL	B
	RR	C			; BC = whole 16-bit words
	LD	A,C
	AND	3
	LD	(RXC_TAIL),A		; 0..3 words left over after the groups
	SRL	B
	RR	C
	SRL	B
	RR	C			; BC = whole four-word groups
	LD	A,C
	EXX
	LD	B,A			; group counter, shadow side
	EXX
	LD	BC,(RXS_SUM)
	LD	A,B
	LD	B,C
	LD	C,A			; enter the byte-swapped domain
	OR	A			; CF = 0 before the ripple starts
	EXX
	INC	B
	DEC	B			; Z iff no groups; leaves CF alone
	EXX
	JR	Z,.SUM_TAIL
.SUM_GROUP
	DUP 4
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,B
	LD	B,A
	EDUP
	EXX
	DJNZ	.SUM_GROUP_MORE
	EXX
	JR	.SUM_TAIL
.SUM_GROUP_MORE
	EXX
	JR	.SUM_GROUP
.SUM_TAIL
	LD	A,(RXC_TAIL)
	EXX
	LD	B,A
	INC	B
	DEC	B			; Z iff no tail words; leaves CF alone
	EXX
	JR	Z,.SUM_ODD
.SUM_TAIL_LOOP
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,C
	LD	C,A
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,B
	LD	B,A
	EXX
	DJNZ	.SUM_TAIL_MORE
	EXX
	JR	.SUM_ODD
.SUM_TAIL_MORE
	EXX
	JR	.SUM_TAIL_LOOP
.SUM_ODD
	LD	A,(RXC_ODD)
	BIT	0,A			; BIT, not OR: the ripple carry is still live
	JR	Z,.SUM_FOLD
	LD	A,(HL)
	LD	(DE),A
	INC	DE
	ADC	A,C
	LD	C,A
	LD	A,0			; not XOR A, which would drop the carry
	ADC	A,B
	LD	B,A
.SUM_FOLD
	LD	H,B
	LD	L,C			; the fixed port is no longer needed
	LD	BC,0
	ADC	HL,BC			; fold the end-around carry once...
	JR	NC,.SUM_DONE
	INC	HL			; ...and again if FFFFh wrapped to zero
.SUM_DONE
	LD	A,H
	LD	H,L
	LD	L,A			; back to the caller's orientation
	LD	(RXS_SUM),HL
	RET

; RXS_POINTER
; In: BC=Window 1 register offset (0 for the fixed FIFO port). Out: HL=mapped
; address. Assumes the ISA window is already open. Same bit pattern as
; @ISA.MAP_POINTER, computed directly from EL3_BASE + offset with a 16-bit
; add so the offset can never mis-carry the way an 8-bit add without the
; explicit INC B some callers use would. Clobbers HL only.
RXS_POINTER
	LD	HL,(EL3_BASE)
	ADD	HL,BC
	SET	6,H
	SET	7,H
	RET

; RX_BEGIN / RX_PAYLOAD / RX_DROP
; One ISA-window session per receive step instead of the several separate
; opens RX_PENDING/READ_FRAME/RX_DISCARD_CURRENT cost when called apart (each
; of SELECT_WINDOW's callers, the RX_STATUS read, the FIFO burst, the padding
; skip and RX_DISCARD used to open and close its own window). Used only by
; tcp_transport.asm's .WAIT_LOOP under TCPX_DIRECT_RX, in place of the
; RX_PENDING+READ_FRAME pair -- RX_PENDING/READ_FRAME themselves are
; untouched and keep serving every other caller (ARP, PING, IFUP, DNS/UDP,
; and FTP, which does not define EL3_SESSION_RX at all).
;
; RX_BEGIN
; In: HL=header destination, BC=header capacity (>0).
; Out: on a usable frame, CF=0 and BC=full frame length (always >=60, i.e.
;      never zero) -- min(capacity,length) bytes are copied to the
;      destination, and the frame stays queued (not yet RX_DISCARDed): it
;      must be closed by exactly one following RX_PAYLOAD or RX_DROP call,
;      before any TX. On an empty/incomplete FIFO, CF=0 and BC=0 -- nothing
;      more is owed. EL3_OK is also 0, so callers must test BC, not A, to
;      tell these two CF=0 outcomes apart. On a bad/oversized/undersized
;      entry, CF=1 with the same EL3_ERR_RX_ERROR/EL3_ERR_ISA_STATE
;      READ_FRAME already uses -- the bad entry is discarded internally (one
;      RX_DISCARD, same as READ_FRAME's own accept rules), so nothing more
;      is owed either.
; Clobbers AF, BC, DE, HL; preserves IX and IY.
RX_BEGIN
	PUSH	IX,IY
	LD	A,EL3_STAGE_RX
	LD	(EL3_LAST_STAGE),A
	LD	(RXS_DESTINATION),HL
	LD	(RXS_CAPACITY),BC
	; RX_STATUS/COMMAND are Window 1 registers; nothing on this receive path
	; leaves Window 1 once SEND_FRAME/RX_PENDING first cache-select it during
	; the handshake, but check anyway -- @EL3.SELECT_WINDOW's own CMD_SYNC
	; needs its own ISA session, so this must happen before @ISA.OPEN below,
	; never inside it.
	LD	A,(@EL3.CURRENT_WINDOW)
	CP	1
	JR	Z,.BEGIN_WINDOW_OK
	LD	A,1
	CALL	@EL3.SELECT_WINDOW
	JP	C,.BEGIN_SELECT_ERROR
.BEGIN_WINDOW_OK
	LD	A,(@EL3.SLOT)
	CALL	@ISA.OPEN
	JP	C,.BEGIN_ISA_ERROR
	LD	BC,EL3_W1_RX_STATUS
	CALL	RXS_POINTER
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = RX_STATUS
	LD	A,D
	AND	HIGH EL3_RX_INCOMPLETE
	JR	NZ,.BEGIN_NONE
	LD	A,D
	OR	E
	JR	Z,.BEGIN_NONE
	BIT	6,D
	JR	NZ,.BEGIN_BAD
	LD	A,D
	AND	0x07
	LD	D,A			; DE = frame length (11-bit field)
	LD	(RXS_LENGTH),DE
	LD	HL,(RXS_LENGTH)
	LD	BC,EL3_FRAME_WIRE_MIN
	OR	A
	SBC	HL,BC
	JR	C,.BEGIN_BAD
	LD	HL,(RXS_LENGTH)
	LD	BC,EL3_FRAME_MAX+1
	OR	A
	SBC	HL,BC
	JR	NC,.BEGIN_BAD
	LD	HL,(RXS_CAPACITY)
	LD	BC,(RXS_LENGTH)
	OR	A
	SBC	HL,BC
	JR	NC,.BEGIN_COPY_LEN	; capacity >= length: copy the whole frame
	LD	BC,(RXS_CAPACITY)	; capacity < length: copy only the header
.BEGIN_COPY_LEN
	LD	DE,(RXS_DESTINATION)
	PUSH	BC
	LD	BC,0
	CALL	RXS_POINTER		; HL = fixed FIFO port
	POP	BC
	CALL	RX_COPY_PLAIN
	CALL	@ISA.CLOSE
	JR	C,.BEGIN_ISA_ERROR
	LD	BC,(RXS_LENGTH)
	XOR	A
	POP	IY,IX
	RET
.BEGIN_BAD
	CALL	@ISA.CLOSE
	JR	C,.BEGIN_ISA_ERROR
	LD	HL,EL3_COUNT_RX
	CALL	@EL3.INC_WORD
	CALL	@EL3.RX_DISCARD_CURRENT
	LD	A,EL3_ERR_RX_ERROR
	SCF
	POP	IY,IX
	RET
.BEGIN_NONE
	CALL	@ISA.CLOSE
	JR	C,.BEGIN_ISA_ERROR
	XOR	A
	LD	BC,0			; EL3_OK is also 0, so callers must not use A
					; alone to tell "nothing queued" from success;
					; BC=0 here (a real frame is always >=60) is
					; the distinguishing signal.
	POP	IY,IX
	RET
.BEGIN_ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	POP	IY,IX
	RET
.BEGIN_SELECT_ERROR
	POP	IY,IX			; A/CF already set by @EL3.SELECT_WINDOW
	RET

; RX_PAYLOAD
; In: DE=destination, BC=byte count (0 is valid: nothing more to copy, but
;     the frame RX_BEGIN left queued still needs discarding).
; Out: A=EL3_OK/CF=0, or explicit EL3_ERR_ISA_STATE/CF=1. Issues exactly one
; RX_DISCARD without waiting for CIP to clear -- the next session's own CIP
; check (WAIT_CIP, el3_regs.asm) absorbs any leftover wait, and losing a
; discard's completion status is harmless (nothing here depends on it; a
; stuck FIFO shows up as the next RX_BEGIN timing out on CIP instead).
; Clobbers AF, BC, DE, HL; preserves IX and IY.
;
; RX_PAYLOAD_SUM is the same call with the copy done by RX_COPY_SUM instead:
; the payload is checksummed as it is read. (RXS_SUM) carries the seed in and
; the accumulator out; BC must be 1..TCP_MSS (RX_COPY_SUM's own limit), so
; this entry is not a substitute for the BC=0 discard-only case.
RX_PAYLOAD_SUM
	LD	A,1
	LD	(RXS_MODE),A
	JR	RX_PAYLOAD_ENTRY
RX_PAYLOAD
	XOR	A
	LD	(RXS_MODE),A
RX_PAYLOAD_ENTRY
	PUSH	IX,IY
	LD	A,EL3_STAGE_RX
	LD	(EL3_LAST_STAGE),A
	; See RX_BEGIN's own check: must happen before @ISA.OPEN, never inside
	; it, and must not disturb the caller's DE/BC (destination/count).
	LD	A,(@EL3.CURRENT_WINDOW)
	CP	1
	JR	Z,.PAYLOAD_WINDOW_OK
	PUSH	BC
	PUSH	DE
	LD	A,1
	CALL	@EL3.SELECT_WINDOW
	POP	DE
	POP	BC
	JR	C,.PAYLOAD_SELECT_ERROR
.PAYLOAD_WINDOW_OK
	LD	A,(@EL3.SLOT)
	CALL	@ISA.OPEN
	JR	C,.PAYLOAD_ISA_ERROR
	LD	A,B
	OR	C
	JR	Z,.PAYLOAD_DISCARD
	PUSH	BC
	LD	BC,0
	CALL	RXS_POINTER		; HL = fixed FIFO port
	POP	BC
	LD	A,(RXS_MODE)
	OR	A
	JR	NZ,.PAYLOAD_SUM_COPY
	CALL	RX_COPY_PLAIN
	JR	.PAYLOAD_DISCARD
.PAYLOAD_SUM_COPY
	CALL	RX_COPY_SUM
.PAYLOAD_DISCARD
	LD	BC,EL3_REG_COMMAND
	CALL	RXS_POINTER
	LD	DE,EL3_CMD_RX_DISCARD
	LD	(EL3_LAST_COMMAND),DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	CALL	@ISA.CLOSE
	JR	C,.PAYLOAD_ISA_ERROR
	XOR	A
	POP	IY,IX
	RET
.PAYLOAD_ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	POP	IY,IX
	RET
.PAYLOAD_SELECT_ERROR
	POP	IY,IX			; A/CF already set by @EL3.SELECT_WINDOW
	RET

; RX_DROP
; Discards the frame RX_BEGIN left queued, without reading anything more.
; Out: A=EL3_OK/CF=0, or explicit EL3_ERR_ISA_STATE/CF=1 (see RX_PAYLOAD,
; whose BC=0 path this reuses -- the only difference is the drop counter).
; Clobbers AF, BC, DE, HL; preserves IX and IY.
RX_DROP
	LD	HL,EL3_COUNT_DROP
	CALL	@EL3.INC_WORD
	LD	BC,0
	JP	RX_PAYLOAD

; TX_BURST
; Writes the preamble, frame and both pad regions @EL3.TX_WRITE_PACKET
; writes in one ISA session instead of four (FIFO_WRITE/FIFO_WRITE/
; FIFO_ZERO/FIFO_ZERO, each opening and closing its own). Reads
; @EL3.TX_PREAMBLE/TX_SOURCE/TX_INPUT_LENGTH/TX_EFFECTIVE_LENGTH, already
; populated by @EL3.TX_CALCULATE_LENGTHS -- same contract and same caller
; (@EL3.SEND_FRAME's .SEND_ATTEMPT) as TX_WRITE_PACKET, which this replaces
; only under EL3_SESSION_RX; TX_WRITE_PACKET itself stays compiled for FTP.
; The FIFO data port is window-independent (unlike RX_STATUS/COMMAND, it
; needs no Window 1 check here -- OPEN_FIFO above never does one either),
; and SEND_FRAME has already selected Window 1 for TX_STATUS/TX_FREE by the
; time this runs regardless.
; Out: A=EL3_OK/CF=0, or explicit EL3_ERR_ISA_STATE/CF=1.
; Clobbers AF, BC, DE, HL; preserves IX and IY.
TX_BURST
	LD	HL,(@EL3.TX_EFFECTIVE_LENGTH)
	LD	BC,(@EL3.TX_INPUT_LENGTH)
	OR	A
	SBC	HL,BC
	LD	(TXB_ZERO_PAD),HL
	LD	HL,(@EL3.TX_EFFECTIVE_LENGTH)
	LD	A,L
	NEG
	AND	3
	LD	(TXB_DWORD_PAD),A
	; TX_WRITE_PACKET (el3_fifo.asm) computes the 4-byte preamble itself,
	; from TX_EFFECTIVE_LENGTH, right before writing it; TX_BURST bypasses
	; that routine entirely, so the same computation has to happen here too.
	LD	HL,(@EL3.TX_EFFECTIVE_LENGTH)
	LD	A,L
	LD	(@EL3.TX_PREAMBLE),A
	LD	A,H
	OR	0x80
	LD	(@EL3.TX_PREAMBLE+1),A
	XOR	A
	LD	(@EL3.TX_PREAMBLE+2),A
	LD	(@EL3.TX_PREAMBLE+3),A
	LD	A,(@EL3.SLOT)
	CALL	@ISA.OPEN
	JP	C,.TXB_ISA_ERROR
	LD	HL,(EL3_BASE)
	SET	6,H
	SET	7,H			; HL = fixed FIFO port
	LD	DE,@EL3.TX_PREAMBLE
	LD	BC,4
	CALL	TXB_WRITE_BARE
	LD	DE,(@EL3.TX_SOURCE)
	LD	BC,(@EL3.TX_INPUT_LENGTH)
	CALL	TXB_WRITE_BARE
	LD	BC,(TXB_ZERO_PAD)
	CALL	TXB_ZERO_BARE
	LD	A,(TXB_DWORD_PAD)
	LD	C,A
	LD	B,0
	CALL	TXB_ZERO_BARE
	CALL	@ISA.CLOSE
	JP	C,.TXB_ISA_ERROR
	XOR	A
	RET
.TXB_ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	RET

; Bare fixed-port FIFO writes, no ISA open/close of their own (TX_BURST
; above already holds one session). In: HL=fixed FIFO port, DE=source (write
; only) or unused (zero), BC=count. Clobbers AF, BC, DE; preserves HL.
TXB_WRITE_BARE
	LD	A,B
	OR	C
	RET	Z
.TXB_WRITE_LOOP
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.TXB_WRITE_LOOP
	RET

TXB_ZERO_BARE
	LD	A,B
	OR	C
	RET	Z
	XOR	A
.TXB_ZERO_LOOP
	LD	D,A
	LD	A,B
	OR	C
	LD	A,D
	JR	Z,.TXB_ZERO_DONE
	LD	(HL),A
	DEC	BC
	JR	.TXB_ZERO_LOOP
.TXB_ZERO_DONE
	RET

	ENDIF

READ_VALUE	DB 0
WRITE_VALUE	DB 0
WRITE_WORD	DW 0
	IFDEF FAST_DATAPATH
FIFO_TAIL	DB 0		; FIFO_READ's 0..7-byte remainder after the groups
	ENDIF
	IFDEF EL3_SESSION_RX
RXC_TAIL	DB 0		; RX_COPY_PLAIN's 0..7-byte / RX_COPY_SUM's 0..3-word
				; remainder after the groups; never both at once
RXC_ODD		DB 0		; RX_COPY_SUM: odd trailing byte to pad
RXS_MODE	DB 0		; 0 = RX_PAYLOAD plain copy, 1 = RX_PAYLOAD_SUM
RXS_SUM		DW 0		; RX_COPY_SUM accumulator, ACCUMULATE orientation
RXS_DESTINATION	DW 0
RXS_CAPACITY	DW 0
RXS_LENGTH	DW 0
TXB_ZERO_PAD	DW 0
TXB_DWORD_PAD	DB 0
	ENDIF

	ENDMODULE
	ENDIF
