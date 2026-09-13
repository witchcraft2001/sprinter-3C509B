; Resident side of TELNET's internal WIN0 modem-page ABI.
; The stage-1 TELNET.EXE preloader has already allocated and filled the cold
; page before MAIN starts.  During a transfer WIN0 is switched to that page;
; its RST vectors tail-call the resident routines below, so DSS calls and
; frame interrupts remain safe.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_TELMODEM_LOADER_ASM
	DEFINE	_TELMODEM_LOADER_ASM

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "telmodem.inc"

	MODULE MODEM

; RESET follows TELNET's BSS clear.  The immutable boot record is outside that
; clear range and is copied back to the active fields every time.
RESET
	XOR A
	LD (TELMODEM_READY),A
	LD A,(TELMODEM_BOOT_VALID)
	CP 0xA5
	JR Z,.boot_ready
	XOR A
	OR A
	RET
.boot_ready
	LD A,(TELMODEM_BOOT_PHYS_PAGE)
	LD (TELMODEM_PHYS_PAGE),A
	LD A,(TELMODEM_BOOT_DSS_PAGE)
	LD (TELMODEM_DSS_PAGE),A
	LD A,(TELMODEM_BOOT_BLOCK_ID)
	LD (TELMODEM_BLOCK_ID),A
	CALL BIND_API
	LD A,1
	LD (TELMODEM_READY),A
	OR A
	RET

; INIT is intentionally small: the page was loaded from this EXE by stage 1.
; Out: CF=0 ready; CF=1, A=0xFF only if the preloader did not provide it.
INIT
	LD A,(TELMODEM_READY)
	OR A
	RET NZ
	CALL RESET
	LD A,(TELMODEM_READY)
	OR A
	RET NZ
	LD A,0xFF
	SCF
	RET

; Preserve ZMODEM's current TCP-tail registers during a first lazy load.
RUN_Z_RECEIVE
	PUSH HL
	PUSH BC
	CALL INIT
	POP BC
	POP HL
	RET C
	LD A,TELMODEM_FN_Z_RECEIVE
	CALL CALL
	OR A
	RET
RUN_Z_REPLAY
	CALL INIT
	RET C
	LD A,TELMODEM_FN_Z_REPLAY
	CALL CALL
	OR A
	RET
RUN_Y_RECEIVE
	CALL INIT
	RET C
	LD A,TELMODEM_FN_Y_RECEIVE
	CALL CALL
	OR A
	RET
RUN_Y_RECEIVE_G
	CALL INIT
	RET C
	LD A,TELMODEM_FN_Y_RECEIVE_G
	CALL CALL
	OR A
	RET
RUN_Y_SEND
	CALL INIT
	RET C
	LD A,TELMODEM_FN_Y_SEND
	CALL CALL
	OR A
	RET

; CALL maps the code page only around one complete modem entry.  A carries a
; TELMODEM_FN_* selector; HL/BC/DE and index registers pass through unchanged.
CALL
	; Preserve the function selector before inspecting resident state. The
	; previous code replaced every selector with TELMODEM_READY (normally 1),
	; so Z_RECEIVE/Y_RECEIVE/Y_SEND all entered Z_REPLAY instead.
	PUSH AF
	LD A,(TELMODEM_READY)
	OR A
	JR NZ,.ready
	POP AF
	LD A,0xFF
	SCF
	RET
.ready
	DI
	IN A,(PAGE0)
	LD (TELMODEM_DSS_PAGE),A
	LD A,(TELMODEM_PHYS_PAGE)
	OUT (PAGE0),A
	EI
	POP AF
	CALL 0x0180
	PUSH AF
	DI
	LD A,(TELMODEM_DSS_PAGE)
	OUT (PAGE0),A
	POP AF
	EI
	RET

FREE
	; All three pages belong to the process and are reclaimed together by DSS
	; on EXIT.  Do not free the cold one independently: a late frame callback
	; may still need its vector page during terminal teardown.
	RET

; RST targets execute in resident WIN1.  Their return address remains valid
; while WIN0 is temporarily switched back to the DSS system page.
DSS_TRAMP
	DI
	PUSH AF
	LD A,(TELMODEM_DSS_PAGE)
	OUT (PAGE0),A
	POP AF
	EI
	RST DSS
	DI
	PUSH AF
	LD A,(TELMODEM_PHYS_PAGE)
	OUT (PAGE0),A
	POP AF
	EI
	RET

BIOS_TRAMP
	DI
	PUSH AF
	LD A,(TELMODEM_DSS_PAGE)
	OUT (PAGE0),A
	POP AF
	EI
	RST BIOS
	DI
	PUSH AF
	LD A,(TELMODEM_PHYS_PAGE)
	OUT (PAGE0),A
	POP AF
	EI
	RET

; IM1 is vectored through the cold page's 0x0038 JP.  DSS RETIs to .resume;
; only then is WIN0 switched back to the modem page.
INT_TRAMP
	PUSH AF
	PUSH HL
	LD A,(TELMODEM_DSS_PAGE)
	OUT (PAGE0),A
	LD HL,.resume
	PUSH HL
	LD HL,0x0038
	JP (HL)
.resume
	DI
	LD A,(TELMODEM_PHYS_PAGE)
	OUT (PAGE0),A
	POP HL
	POP AF
	EI
	RETI

; ZMODEM's old UART source requested millisecond sleeps.  The target's
; S9APP.WAIT_TICK is calibrated to one millisecond and does not open ISA.
DELAY_MS
	LD A,H
	OR L
	RET Z
.loop
	CALL @S9APP.WAIT_TICK
	DEC HL
	LD A,H
	OR L
	JR NZ,.loop
	RET

; Only a synthetic ZM_TEST_REFILL build uses this hook.  Production has no
; alternate byte source, so return an explicit bounded failure.
TEST_FILL
	LD A,0xFF
	SCF
	RET

; This pointer table is the sole hot-code coupling of the cold page.
BIND_API
	LD HL,DSS_TRAMP
	LD (TELMODEM_API_DSS),HL
	LD HL,BIOS_TRAMP
	LD (TELMODEM_API_BIOS),HL
	LD HL,INT_TRAMP
	LD (TELMODEM_API_INT),HL
	LD HL,@MAIN.OUTPUT_BYTE
	LD (TELMODEM_API_OUTPUT),HL
	LD HL,@MAIN.PROCESS_RX_BYTE
	LD (TELMODEM_API_PROCESS),HL
	LD HL,@MAIN.RX_DRAIN
	LD (TELMODEM_API_RX_DRAIN),HL
	LD HL,@MAIN.RX_DRAIN_WAIT
	LD (TELMODEM_API_RX_WAIT),HL
	LD HL,@MAIN.NET_SEND
	LD (TELMODEM_API_NET_SEND),HL
	LD HL,DELAY_MS
	LD (TELMODEM_API_DELAY),HL
	LD HL,TEST_FILL
	LD (TELMODEM_API_TEST_FILL),HL
	OR A
	RET

	ENDMODULE
	ENDIF
