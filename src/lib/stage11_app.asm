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

; ALLOCATE_FRESH makes the runtime area deterministic, then copies the saved
; command into it. Stage 12 runs the standard layout and already owns WIN2, so
; it has no page to claim and cannot fail; every other caller still maps a
; fresh page into WIN1. The caller must not print before this returns, because
; the command record it installs is what the CLI parses.
ALLOCATE_FRESH
	PUSH	IY
	IFDEF STAGE12_LAYOUT
	; No GETMEM: WIN2 is the program's own second window. It still holds
	; whatever the previous program left there, and the code below expects the
	; zero-filled page a fresh GETMEM used to hand back, so clear it -- up to
	; the command copy only, since the live stack sits above that.
	LD	HL,PAGE_BASE
	LD	DE,PAGE_BASE+1
	IFDEF STAGE13_LAYOUT
	; FTP's string block runs past S10_PAGE_COMMAND_BUFFER (F13_USER starts
	; exactly there), so clear through its end instead and leave the record
	; where SAVE_COMMAND put it -- see the command-copy branch below.
	LD	BC,F13_OUTPUT_OVERRIDE+96-PAGE_BASE-1
	ELSE
	LD	BC,S10_PAGE_COMMAND_BUFFER-PAGE_BASE-1
	ENDIF
	LD	(HL),0
	LDIR
	CALL	@S9APP.CLEAR
	ELSE
	LD	B,1
	LD	C,DSS_GETMEM
	RST	DSS
	JP	C,.FAIL
	LD	E,A
	PUSH	DE
	LD	B,0
	LD	C,DSS_SETWIN1
	RST	DSS
	POP	DE
	JP	C,.SET_FAIL
	CALL	@S9APP.CLEAR
	LD	A,E
	LD	(NETDRV_MEMORY_BLOCK),A
	LD	A,1
	LD	(NETDRV_PAGE_ALLOCATED),A
	ENDIF
	IFDEF STAGE13_LAYOUT
	; No page copy: F13_USER/F13_PASS/F13_OUTPUT_OVERRIDE (memory.inc) own
	; the S10_PAGE_COMMAND_BUFFER range, and PARSE_FTP writes -u/-p/-o into
	; them while it is still tokenising the very line it is reading. Parsing
	; the WIN1 copy instead keeps the record clear of everything the parser
	; writes; the standard layout never remaps WIN1, so it stays valid for
	; the whole run.
	LD	IX,S10_COMMAND_BUFFER
	ELSE
	LD	HL,S10_COMMAND_BUFFER
	LD	A,(HL)
	LD	C,A
	LD	B,0
	INC	BC
	LD	DE,S10_PAGE_COMMAND_BUFFER
	LDIR
	LD	IX,S10_PAGE_COMMAND_BUFFER
	ENDIF
	LD	HL,0
	LD	(S11_NEXT_LOCAL_PORT),HL
	XOR	A
	POP	IY
	RET
	IFNDEF STAGE12_LAYOUT
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
	ENDIF

	ENDMODULE
	ENDIF
