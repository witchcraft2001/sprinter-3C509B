; Stage 11 command-line bootstrap for one private DSS page.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_STAGE11_APP_ASM
	DEFINE	_STAGE11_APP_ASM

	INCLUDE "dss.inc"
	INCLUDE "memory.inc"

	MODULE S11APP

; SAVE_COMMAND runs before the page is claimed and preserves the complete DSS
; record. The destination is outside the window about to be remapped, so the
; record survives wherever DSS chose to put the original.
SAVE_COMMAND
	PUSH	IY
	PUSH	IX
	POP	HL
	LD	A,(HL)
	LD	C,A
	LD	B,0
	INC	BC
	LD	DE,S10_COMMAND_BUFFER
	LDIR
	LD	IX,S10_COMMAND_BUFFER
	POP	IY
	RET

; ALLOCATE_FRESH maps one page, then copies the saved command into that page.
; Stage 12's image occupies WIN1, so it claims WIN2; every other caller is the
; other way round. The caller must not print before this returns: the entry
; stack is still in the image window, which BIOS WIN_MOVE remaps on a scroll.
ALLOCATE_FRESH
	PUSH	IY
	LD	B,1
	LD	C,DSS_GETMEM
	RST	DSS
	JP	C,.FAIL
	LD	E,A
	PUSH	DE
	LD	B,0
	IFDEF STAGE12_LAYOUT
	LD	C,DSS_SETWIN2
	ELSE
	LD	C,DSS_SETWIN1
	ENDIF
	RST	DSS
	POP	DE
	JP	C,.SET_FAIL
	CALL	@S9APP.CLEAR
	LD	A,E
	LD	(NETDRV_MEMORY_BLOCK),A
	LD	A,1
	LD	(NETDRV_PAGE_ALLOCATED),A
	LD	HL,S10_COMMAND_BUFFER
	LD	A,(HL)
	LD	C,A
	LD	B,0
	INC	BC
	LD	DE,S10_PAGE_COMMAND_BUFFER
	LDIR
	LD	IX,S10_PAGE_COMMAND_BUFFER
	LD	HL,0
	LD	(S11_NEXT_LOCAL_PORT),HL
	XOR	A
	POP	IY
	RET
.SET_FAIL
	PUSH	AF
	LD	A,E
	LD	C,DSS_FREEMEM
	RST	DSS
	POP	AF
.FAIL
	LD	A,EL3_ERR_NO_MEMORY
	SCF
	POP	IY
	RET

	ENDMODULE
	ENDIF
