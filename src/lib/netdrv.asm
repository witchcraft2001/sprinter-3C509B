; Backend-neutral NETDRV provider for the 3Com EtherLink III core.
; No register/FIFO operation is duplicated here: all hardware work is EL3.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_NETDRV_ASM
	DEFINE	_NETDRV_ASM

	INCLUDE "el3.inc"
	INCLUDE "netdrv.inc"
	INCLUDE "memory.inc"

	MODULE NETDRV

; INIT
; In: HL -> versioned NETDRV config. Out: stable A/CF status.
; Clobbers AF/BC/DE/HL; preserves IX/IY. AUTO probes slots 0 then 1 only.
; EXPLICIT probes only the configured slot; a pinned slot whose DISCOVER
; finds no adapter falls back to the AUTO probe, hinted with the pinned slot
; (so a one-off glitch is retried before the other slot gets its turn). A
; rejected slot/ID-port or a failed ACTIVATE keeps its own status.
INIT
	PUSH	IX,IY
	LD	(NETDRV_SAVED_IX),HL
	LD	BC,NETDRV_CONFIG_LENGTH
	CALL	VALIDATE_BUFFER
	JP	C,.RETURN
	LD	IX,(NETDRV_SAVED_IX)
	LD	A,(IX+NETDRV_CFG_VERSION)
	CP	NETDRV_CONFIG_VERSION
	JP	NZ,.BAD_CONFIG
	LD	A,(IX+NETDRV_CFG_LENGTH)
	CP	NETDRV_CONFIG_LENGTH
	JP	NZ,.BAD_CONFIG
	LD	L,(IX+NETDRV_CFG_IDPORT)
	LD	H,(IX+NETDRV_CFG_IDPORT+1)
	LD	A,(IX+NETDRV_CFG_MODE)
	CP	NETDRV_MODE_AUTO
	IFDEF	UNET_DLL
	JP	Z,.BAD_CONFIG		; AUTO is rejected upstream (env NET_HW=AUTO -> NERR_NONET); a
					; config that reaches here with it anyway is malformed, not
					; a slot to probe -- this DLL never probes (see below).
	ELSE
	JR	Z,.AUTO
	ENDIF
	CP	NETDRV_MODE_EXPLICIT
	JP	NZ,.BAD_CONFIG
	LD	A,(IX+NETDRV_CFG_SLOT)
	LD	(NETDRV_SELECTED_SLOT),A
	CALL	@EL3.CONFIGURE
	JP	C,.RETURN
	CALL	@EL3.DISCOVER
	IFDEF	UNET_DLL
	JP	C,.RETURN		; no AUTO fallback in this DLL: report DISCOVER's own status
	ELSE
	JR	C,.AUTO
	ENDIF
	LD	L,(IX+NETDRV_CFG_BASE)
	LD	H,(IX+NETDRV_CFG_BASE+1)
	LD	A,1
	CALL	@EL3.ACTIVATE
	JP	C,.ACTIVATE_FAILED
	JR	.ACTIVE
	IFNDEF	UNET_DLL
; Only DISCOVER decides that a pinned slot missed: it is the one step that
; asks the hardware whether an adapter answers there, so its failure falls
; back to the same probe AUTO uses, hinted with the pinned slot (a card that
; only glitched is retried once before the other slot gets its turn).
; CONFIGURE validates slot/ID-port and touches no hardware, so its
; EL3_ERR_PARAMETER is returned as-is -- probing would repeat the identical
; rejection on both slots and report the bad ID port as "card not found".
; A failed ACTIVATE is not a missed pin either: the card answered ID, so a
; bad base is reported as-is via .ACTIVATE_FAILED.
; AUTO probing itself is dropped entirely for the DLL: NETINIT's own env
; parsing already rejects NET_HW=AUTO before NETDRV.INIT is ever called
; (decision recorded in the plan), so keeping this ~60-byte loop linked in
; would only spend image budget on a path that never runs.
.AUTO
	LD	A,(IX+NETDRV_CFG_SLOT)
	CP	2
	JR	C,.AUTO_FROM_HINT
	XOR	A
.AUTO_FROM_HINT
	LD	(NETDRV_PROBE_SLOT),A
	LD	B,2
.AUTO_LOOP
	PUSH	BC
	LD	A,(NETDRV_PROBE_SLOT)
	LD	(NETDRV_SELECTED_SLOT),A
	LD	L,(IX+NETDRV_CFG_IDPORT)
	LD	H,(IX+NETDRV_CFG_IDPORT+1)
	CALL	@EL3.CONFIGURE
	JR	C,.AUTO_NEXT_POP
	CALL	@EL3.DISCOVER
	JR	C,.AUTO_NEXT_POP
	XOR	A
	LD	HL,0
	CALL	@EL3.ACTIVATE
	POP	BC
	JR	C,.ACTIVATE_FAILED
	JR	.ACTIVE
.AUTO_NEXT_POP
	POP	BC
	LD	A,(NETDRV_PROBE_SLOT)
	XOR	1
	LD	(NETDRV_PROBE_SLOT),A
	DJNZ	.AUTO_LOOP
	LD	A,EL3_ERR_NOT_FOUND
	SCF
	JP	.RETURN
	ENDIF	; UNET_DLL
.ACTIVE
	LD	(NETDRV_SELECTED_BASE),HL
	LD	A,1
	LD	(NETDRV_ACTIVE),A
	LD	A,(IX+NETDRV_CFG_MAC_FLAGS)
	AND	NETDRV_MAC_OVERRIDE
	JR	Z,.CARD_INIT
	PUSH	IX
	POP	HL
	LD	DE,NETDRV_CFG_MAC
	ADD	HL,DE
	LD	DE,EL3_MAC
	LD	BC,6
	LDIR
.CARD_INIT
	CALL	@EL3.INIT
	JR	C,.INIT_FAILED
	LD	HL,EL3_MAC
	LD	DE,NETDRV_STATION_MAC
	LD	BC,6
	LDIR
	XOR	A
	JR	.RETURN
.INIT_FAILED
	LD	(NETDRV_SAVED_ERROR),A
	CALL	@EL3.DONE
	XOR	A
	LD	(NETDRV_ACTIVE),A
	LD	A,(NETDRV_SAVED_ERROR)
	SCF
	JR	.RETURN
.ACTIVATE_FAILED
	LD	(NETDRV_SAVED_ERROR),A
	CALL	@EL3.DONE
	XOR	A
	LD	(NETDRV_ACTIVE),A
	LD	A,(NETDRV_SAVED_ERROR)
	SCF
	JR	.RETURN
.BAD_CONFIG
	LD	A,NETDRV_ERR_CONFIG
	SCF
.RETURN
	POP	IY,IX
	RET

; DONE is idempotent and always leaves NETDRV inactive.
DONE
	PUSH	IX,IY
	LD	A,(NETDRV_ACTIVE)
	OR	A
	JR	Z,.OK
	CALL	@EL3.DONE
	LD	(NETDRV_SAVED_ERROR),A
	XOR	A
	LD	(NETDRV_ACTIVE),A
	LD	A,(NETDRV_SAVED_ERROR)
	OR	A
	JR	Z,.OK
	SCF
	JR	.RETURN
.OK
	XOR	A
.RETURN
	POP	IY,IX
	RET

; SEND_FRAME / READ_FRAME accept only caller-owned, non-wrapping buffers.
; READ_FRAME delegates the one-and-only packet consumption rule to EL3.
SEND_FRAME
	PUSH	IX,IY
	LD	(NETDRV_BUFFER_PTR),HL
	LD	(NETDRV_BUFFER_LEN),BC
	CALL	VALIDATE_BUFFER
	JR	C,.RETURN
	LD	HL,(NETDRV_BUFFER_PTR)
	LD	BC,(NETDRV_BUFFER_LEN)
	CALL	@EL3.SEND_FRAME
.RETURN
	POP	IY,IX
	RET

RX_PENDING
	PUSH	IX,IY
	CALL	@EL3.RX_PENDING
	POP	IY,IX
	RET

READ_FRAME
	PUSH	IX,IY
	LD	(NETDRV_BUFFER_PTR),HL
	LD	(NETDRV_BUFFER_LEN),BC
	CALL	VALIDATE_BUFFER
	JR	C,.RETURN
	LD	HL,(NETDRV_BUFFER_PTR)
	LD	BC,(NETDRV_BUFFER_LEN)
	CALL	@EL3.READ_FRAME
.RETURN
	POP	IY,IX
	RET

	IFNDEF STAGE12_LAYOUT
DISCARD_FRAME
	PUSH	IX,IY
	CALL	@EL3.DISCARD_FRAME
	POP	IY,IX
	RET

SNAPSHOT
	PUSH	IX,IY
	LD	(NETDRV_BUFFER_PTR),HL
	LD	BC,EL3_SNAPSHOT_LENGTH
	LD	(NETDRV_BUFFER_LEN),BC
	CALL	VALIDATE_BUFFER
	JR	C,.RETURN
	LD	HL,(NETDRV_BUFFER_PTR)
	CALL	@EL3.SNAPSHOT
.RETURN
	POP	IY,IX
	RET

LINK_STATE
	PUSH	IX,IY
	CALL	@EL3.LINK_STATE
	POP	IY,IX
	RET

; In: BC=finite EL3 wait quanta. Zero is rejected instead of becoming an
; accidental unbounded 16-bit countdown.
WAIT_LINK_UP
	PUSH	IX,IY
	LD	A,B
	OR	C
	JR	Z,.BAD
	CALL	@EL3.WAIT_LINK_UP
	POP	IY,IX
	RET
.BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET
	ENDIF

; VALIDATE_BUFFER
; In: HL=start, BC=length. End is exclusive. Reject zero, wrap, >=C000,
; overlap with the DLL's load window, and buffers that would consume the last
; 256 bytes below the current stack. The standalone WIN1 mapping is valid.
VALIDATE_BUFFER
	LD	A,B
	OR	C
	JR	Z,.BAD
	LD	(NETDRV_BUFFER_PTR),HL
	LD	(NETDRV_BUFFER_LEN),BC
	ADD	HL,BC
	JR	C,.BAD
	LD	DE,0xC001
	OR	A
	SBC	HL,DE
	JR	NC,.BAD
	LD	HL,(NETDRV_BUFFER_PTR)
	LD	BC,(NETDRV_BUFFER_LEN)
	ADD	HL,BC			; exclusive end
	IF NETDRV_DLL_WINDOW = NETDRV_DLL_WIN1
		LD	DE,0x4000
		LD	BC,(NETDRV_BUFFER_PTR)
		LD	A,B
		CP	0x80
		JR	NC,.NO_DLL_OVERLAP
		OR	A
		SBC	HL,DE
		JR	NC,.BAD
.NO_DLL_OVERLAP
	ENDIF
	IF NETDRV_DLL_WINDOW = NETDRV_DLL_WIN2
		LD	DE,0x8000
		LD	BC,(NETDRV_BUFFER_PTR)
		LD	A,B
		CP	0xC0
		JR	NC,.NO_DLL_OVERLAP
		OR	A
		SBC	HL,DE
		JR	NC,.BAD
.NO_DLL_OVERLAP
	ENDIF
	IFNDEF	UNET_DLL
	; Resident buffers at/above 8000h must end no closer than 256 bytes to SP.
	; Skipped for the DLL: this code runs on the CALLER's stack (SP may be
	; anywhere in the consumer's own address space, e.g. WIN1 while this
	; image's own RX buffer sits at WIN2+BSS_RX), so "256 bytes below SP"
	; is meaningless here and would reject this DLL's own internal buffers
	; for no reason (see the plan's own note on this exact failure mode).
	LD	HL,(NETDRV_BUFFER_PTR)
	BIT	7,H
	JR	Z,.OK
	LD	BC,(NETDRV_BUFFER_LEN)
	ADD	HL,BC
	EX	DE,HL
	LD	HL,0
	ADD	HL,SP
	LD	BC,0x0100
	OR	A
	SBC	HL,BC
	OR	A
	SBC	HL,DE
	JR	C,.BAD
	ENDIF
.OK
	XOR	A
	RET
.BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

NETDRV_PROBE_SLOT	DB 0
NETDRV_SAVED_ERROR	DB 0

	ENDMODULE
	ENDIF
