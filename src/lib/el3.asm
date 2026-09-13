; Read-only 3C509B discovery, EEPROM and activation.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_EL3_ASM
	DEFINE	_EL3_ASM

	INCLUDE "sprinter.inc"
	INCLUDE "isa.inc"
	INCLUDE "el3.inc"
	INCLUDE "memory.inc"

	MODULE EL3

; CONFIGURE
; In: A=slot, HL=ID port. Out: EL3_OK/CF=0 or explicit error/CF=1.
; Preserves IX and IY.
CONFIGURE
	PUSH	IX,IY
	CP	2
	JR	NC,.BAD
	LD	(SLOT),A
	LD	A,H
	CP	0x01
	JR	NZ,.BAD
	LD	A,L
	AND	0x0F
	JR	NZ,.BAD
	LD	A,L
	CP	0xF1
	JR	NC,.BAD
	LD	(EL3_IDPORT),HL
	XOR	A
	POP	IY,IX
	RET
.BAD
	LD	A,EL3_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET

; DISCOVER
; Reads all 64 EEPROM words through the ID port and validates IDs, MAC and
; checksums. It never activates or writes EEPROM.
;
; It attaches to a live adapter first and only resets one that will not answer.
; The ID-port global reset turns the adapter off and on again, and with it the
; 10baseT transceiver: the link drops, and the switch port then needs seconds
; before it forwards a frame again. Doing that at every program start is what
; put a multi-second pause in front of the first frame every utility sends --
; NETPROF on a real Sprinter resolves its first target in 2..6 s after a reset
; and in 0 s without one, and a resident packet driver of the kind the sibling
; kits load does not pay it because it comes up once per boot rather than once
; per program.
;
; The reset stays as what it always was, a recovery: an adapter that does not
; produce a valid EEPROM image gets one and is tried again. Nothing else is
; lost by attaching, because EL3.INIT disables RX and TX, resets both FIFOs,
; clears the loopback bit and rewrites the station address regardless of which
; pass got here, so a fast attach still starts from a known datapath.
;
; Out: EL3_OK/CF=0 or explicit error/CF=1. ATTACH_RESET records which pass
; answered. Preserves IX and IY.
DISCOVER
	PUSH	IX,IY
	LD	HL,0
	LD	(EL3_LAST_TICKS),HL
	XOR	A
	IFDEF EL3_ATTACH_PROBE
	LD	A,(FORCE_RESET)		; NETPROF -r: start at the reset pass, so
	ENDIF				; the two costs can be measured side by side
	LD	(ATTACH_RESET),A
	CALL	.PASS
	JR	NC,.RETURN
	; BIT reads the flag without touching A or the carry, so the first
	; pass's status and its failure both survive the decision to retry.
	LD	HL,ATTACH_RESET
	BIT	7,(HL)
	JR	NZ,.RETURN		; the reset pass has already run
	LD	(HL),EL3_ID_GLOBAL_RESET
	CALL	.PASS
.RETURN
	POP	IY,IX
	RET

; One discovery pass. Out: EL3_OK/CF=0 or error/CF=1; clobbers AF/BC/DE/HL.
.PASS
	LD	A,EL3_STAGE_RESET
	LD	(EL3_LAST_STAGE),A
	CALL	ID_SEQUENCE
	RET	C
	LD	A,(ATTACH_RESET)	; the command to issue, or zero to attach
	OR	A
	JR	Z,.TAG
	CALL	ID_WRITE
	RET	C
	CALL	WAIT_ONE_QUANTUM
	CALL	ID_SEQUENCE
	RET	C
.TAG
	LD	A,EL3_ID_TAG_ZERO
	CALL	ID_WRITE
	RET	C
	LD	A,EL3_STAGE_EEPROM
	LD	(EL3_LAST_STAGE),A
	LD	HL,EEPROM_BUFFER
	XOR	A
.EEPROM_LOOP
	PUSH	AF,HL
	CALL	ID_READ_WORD
	JR	C,.READ_FAILED
	EX	DE,HL
	POP	HL,AF
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	INC	A
	CP	0x40
	JR	NZ,.EEPROM_LOOP
	LD	A,EL3_STAGE_VALIDATE
	LD	(EL3_LAST_STAGE),A
	JP	@EL3ALG.VALIDATE
.READ_FAILED
	POP	HL			; discard the saved word index; POP and
	INC	SP			; INC SP leave ID_READ_WORD's status and
	INC	SP			; carry untouched
	RET

; ACTIVATE
; In: A=0 for EEPROM base, A=1 for explicit base in HL.
; Out: active base in HL and EL3_BASE, EL3_OK/CF=0 or error/CF=1.
; Preserves IX and IY.
ACTIVATE
	PUSH	IX,IY
	LD	D,A
	LD	A,EL3_STAGE_ACTIVATE
	LD	(EL3_LAST_STAGE),A
	LD	A,D
	OR	A
	JR	NZ,.EXPLICIT
	IFDEF	UNET_DLL
	; This DLL's own netdrv.asm always calls ACTIVATE with A=1: NETDRV_MODE
	; AUTO is rejected upstream, at NETINIT's own env parsing (NET_HW=AUTO
	; -> NERR_NONET before NETDRV.INIT ever runs) -- so the EEPROM-base
	; branch below is provably unreachable and not linked in.
	LD	A,EL3_ERR_PARAMETER
	SCF
	JR	.RETURN
	ELSE
	LD	A,(EEPROM_BUFFER + 0x08*2)
	AND	0x1F
	CALL	@EL3ALG.BASE_DECODE
	JR	C,.RETURN
	LD	(EL3_BASE),HL
	LD	A,EL3_ID_ACTIVATE_EEPROM
	JR	.WRITE_ACTIVATE
	ENDIF
.EXPLICIT
	CALL	@EL3ALG.BASE_ENCODE
	JR	C,.RETURN
	LD	(EL3_BASE),HL
	OR	EL3_ID_ACTIVATE_BASE
.WRITE_ACTIVATE
	CALL	ID_WRITE
	JR	C,.RETURN
	CALL	VERIFY_ACTIVE
	JR	C,.RETURN
	LD	HL,(EL3_BASE)
	XOR	A
.RETURN
	POP	IY,IX
	RET

; VERIFY_ACTIVE
; Reads Window 0 manufacturer/product registers using adjacent low/high cycles.
; Preserves IX and IY.
VERIFY_ACTIVE
	PUSH	IX,IY
	LD	A,EL3_STAGE_VERIFY
	LD	(EL3_LAST_STAGE),A
	LD	E,EL3_REG_MFG_ID
	CALL	READ16
	JR	C,.RETURN
	LD	DE,EL3_MFG_3COM
	OR	A
	SBC	HL,DE
	JR	NZ,.BAD
	LD	E,EL3_REG_PRODUCT_ID
	CALL	READ16
	JR	C,.RETURN
	PUSH	HL
	LD	DE,EL3_PRODUCT_3C509B_TPO
	OR	A
	SBC	HL,DE
	POP	HL
	JR	Z,.PRODUCT_OK
	LD	DE,EL3_PRODUCT_3C509B_TP
	OR	A
	SBC	HL,DE
	JR	NZ,.BAD
.PRODUCT_OK
	XOR	A
.RETURN
	POP	IY,IX
	RET
.BAD
	LD	A,EL3_ERR_VERIFY
	SCF
	JR	.RETURN

; ID_SEQUENCE
; Sends two zero selector bytes and exactly 255 LFSR bytes (FF through 98).
; Preserves IX and IY.
ID_SEQUENCE
	PUSH	IX,IY
	LD	A,(SLOT)
	CALL	@ISA.OPEN
	JR	C,.ISA_ERROR
	LD	BC,(EL3_IDPORT)
	CALL	@ISA.MAP_POINTER
	XOR	A
	LD	(HL),A
	LD	(HL),A
	LD	C,EL3_LFSR_SEED
	LD	B,0xFF
.LOOP
	LD	A,C
	LD	(HL),A
	CALL	@EL3ALG.LFSR_NEXT
	LD	C,A
	DJNZ	.LOOP
	CALL	@ISA.CLOSE
	JR	C,.ISA_ERROR
	LD	A,C
	CP	EL3_LFSR_SEED
	JR	NZ,.INTERNAL
	XOR	A
	POP	IY,IX
	RET
.ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	POP	IY,IX
	RET
.INTERNAL
	LD	A,EL3_ERR_VERIFY
	SCF
	POP	IY,IX
	RET

; ID_WRITE
; In: A=ID command. Out: explicit status. Preserves IX and IY.
ID_WRITE
	PUSH	IX,IY
	LD	(ID_COMMAND),A
	LD	BC,(EL3_IDPORT)
	LD	A,(SLOT)
	LD	D,A
	LD	A,(ID_COMMAND)
	CALL	@ISA.WRITE8
	JR	NC,.OK
	LD	A,EL3_ERR_ISA_STATE
	SCF
	POP	IY,IX
	RET
.OK
	XOR	A
	POP	IY,IX
	RET

; ID_READ_WORD
; In: A=EEPROM address 00..3F. Out: HL=word and CF=0, or error.
; The documented 162 us operation is followed by one CYCLES21 quantum;
; the ISA window is closed for the entire wait.
; Preserves IX and IY.
ID_READ_WORD
	PUSH	IX,IY
	CP	0x40
	JR	NC,.BAD_ADDRESS
	OR	EL3_ID_EEPROM_READ
	CALL	ID_WRITE
	JR	C,.RETURN
	CALL	WAIT_ONE_QUANTUM
	LD	A,(SLOT)
	CALL	@ISA.OPEN
	JR	C,.ISA_ERROR
	LD	BC,(EL3_IDPORT)
	CALL	@ISA.MAP_POINTER
	LD	DE,0
	LD	B,16
.BIT_LOOP
	SLA	E
	RL	D
	LD	A,(HL)
	AND	1
	OR	E
	LD	E,A
	DJNZ	.BIT_LOOP
	CALL	@ISA.CLOSE
	JR	C,.ISA_ERROR
	EX	DE,HL
	XOR	A
.RETURN
	POP	IY,IX
	RET
.BAD_ADDRESS
	LD	A,EL3_ERR_PARAMETER
	SCF
	JR	.RETURN
.ISA_ERROR
	LD	A,EL3_ERR_ISA_STATE
	SCF
	JR	.RETURN

	IFNDEF STAGE12_LAYOUT	; unused by WGET
; WINDOW_EEPROM_READ
; In: A=address 00..3F. Out: HL=word. READ opcode only; no write/erase API.
; Busy is checked before and after READ with finite CYCLES21 timing.
; Preserves IX and IY.
WINDOW_EEPROM_READ
	PUSH	IX,IY
	CP	0x40
	JR	NC,.BAD
	LD	(CURRENT_EEPROM_ADDRESS),A
	CALL	WAIT_EEPROM_READY
	JR	C,.RETURN
	LD	A,(CURRENT_EEPROM_ADDRESS)
	OR	EL3_ID_EEPROM_READ
	LD	L,A
	LD	H,0
	LD	E,EL3_REG_EEPROM_CMD
	CALL	WRITE16
	JR	C,.RETURN
	CALL	WAIT_ONE_QUANTUM
	CALL	WAIT_EEPROM_READY
	JR	C,.RETURN
	LD	E,EL3_REG_EEPROM_DATA
	CALL	READ16
.RETURN
	POP	IY,IX
	RET
.BAD
	LD	A,EL3_ERR_PARAMETER
	SCF
	JR	.RETURN

; WAIT_EEPROM_READY
; Polls EBY with ISA closed and one CYCLES21 quantum between reads.
; Inside the same guard as its only caller: the ID-port EEPROM path
; (ID_READ_WORD) has its own timing, so a STAGE12 build that drops
; WINDOW_EEPROM_READ was carrying this as dead weight.
WAIT_EEPROM_READY
	LD	HL,0
	LD	(EL3_LAST_TICKS),HL
.POLL
	LD	E,EL3_REG_EEPROM_CMD
	CALL	READ16
	RET	C
	LD	(EL3_LAST_STATUS),HL
	BIT	7,H
	JR	Z,.READY
	LD	HL,(EL3_LAST_TICKS)
	LD	DE,EL3_WAIT_QUANTA
	OR	A
	SBC	HL,DE
	JR	NC,.TIMEOUT
	CALL	WAIT_QUANTUM
	LD	HL,(EL3_LAST_TICKS)
	INC	HL
	LD	(EL3_LAST_TICKS),HL
	JR	.POLL
.READY
	XOR	A
	RET

.TIMEOUT
	LD	HL,EL3_COUNT_TIMEOUT
	CALL	INC_WORD
	LD	A,EL3_ERR_TIMER
	SCF
	RET
	ENDIF

; WAIT_ONE_QUANTUM
; Close-window cycle delay used after ID reset and EEPROM READ.
WAIT_ONE_QUANTUM
	CALL	WAIT_QUANTUM
	LD	HL,1
	LD	(EL3_LAST_TICKS),HL
	XOR	A
	RET

SLOT			DB ISA_SLOT_1
CURRENT_EEPROM_ADDRESS	DB 0
ID_COMMAND		DB 0
; Zero while attaching to a live adapter, EL3_ID_GLOBAL_RESET on the recovery
; pass: DISCOVER writes it straight to the ID port and reads back which pass
; answered. Its top bit is the "has already reset" test, so any value stored
; here must keep bit 7 set.
ATTACH_RESET		DB 0
	IFDEF EL3_ATTACH_PROBE
FORCE_RESET		DB 0	; same encoding; set by NETPROF -r
	ENDIF

	ENDMODULE
	ENDIF
