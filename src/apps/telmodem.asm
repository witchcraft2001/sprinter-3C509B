; ======================================================
; Internal pageable ZMODEM/YMODEM engine for TELNET.EXE.
;
; This is a raw WIN0 payload embedded in the monolithic EXE, not a separate
; DSS executable or companion file.  The stage-1 loader allocates a page and
; streams it from the same EXE while ISA is closed; MAIN maps it only while a
; transfer is active.  RST vectors tail-call resident WIN1 trampolines, so
; imported modem engines may safely use DSS file/console services and frame
; interrupts continue to reach DSS.
; SPDX-License-Identifier: BSD-3-Clause
; ======================================================

	DEVICE NOSLOT64K

	DEFINE RUNTIME_BASE 0xB000
	DEFINE STAGE9_LAYOUT
	DEFINE STAGE10_PAGE_LAYOUT
	DEFINE STAGE10_DNS
	DEFINE STAGE11_LAYOUT
	DEFINE STAGE12_LAYOUT
	INCLUDE "macro.inc"
	INCLUDE "dss.inc"
	INCLUDE "memory.inc"
	INCLUDE "telmodem.inc"

; Compatibility names retained by the transport-neutral modem sources.
DSS_KCLEAR	EQU DSS_K_CLEAR
REG_FCR		EQU 0

; WIN0 vectors are deliberately only jumps.  Each target is a cold-to-hot
; tail-call wrapper below, which leaves every DSS argument register intact.
	ORG 0x0000
	DS 8,0
	JP MODEMAPI.BIOS
	DS 5,0
	JP MODEMAPI.DSS
	DS 29,0
	JP MODEMAPI.INT
	DS 5,0
	JP MODEMAPI.INT
	DS 69,0

; SAVEBIN/--raw do not materialise an ORG gap.  Emit the reserved vector area
; explicitly so MODEM.CALL's fixed CALL 0x0180 reaches this dispatcher after
; the file has been copied verbatim into the allocated page.
	DS 0x100,0

; Dispatcher entered by MAIN.MODEM.CALL.  HL/BC are live ZMODEM receive-tail
; arguments, so selection inspects only A before jumping to the engine.
MODEM_ENTRY
	CP TELMODEM_FN_Z_RECEIVE
	JP Z,ZM.RECEIVE
	CP TELMODEM_FN_Z_REPLAY
	JP Z,ZM.REPLAY_TAIL
	CP TELMODEM_FN_Y_RECEIVE
	JP Z,YM.RECEIVE
	CP TELMODEM_FN_Y_RECEIVE_G
	JP Z,YM.RECEIVE_G
	CP TELMODEM_FN_Y_SEND
	JP Z,YM.SEND
	SCF
	RET

; API tail-call wrappers.  PUSH/EX (SP),HL/RET loads the target from the
; resident pointer table without destroying a modem routine's HL/BC/DE input.
	MODULE MODEMAPI

BIOS
	PUSH HL
	LD HL,(TELMODEM_API_BIOS)
	EX (SP),HL
	RET
DSS
	PUSH HL
	LD HL,(TELMODEM_API_DSS)
	EX (SP),HL
	RET
INT
	PUSH HL
	LD HL,(TELMODEM_API_INT)
	EX (SP),HL
	RET
OUTPUT_BYTE
	PUSH HL
	LD HL,(TELMODEM_API_OUTPUT)
	EX (SP),HL
	RET
PROCESS_RX_BYTE
	PUSH HL
	LD HL,(TELMODEM_API_PROCESS)
	EX (SP),HL
	RET
RX_DRAIN
	PUSH HL
	LD HL,(TELMODEM_API_RX_DRAIN)
	EX (SP),HL
	RET
RX_DRAIN_WAIT
	PUSH HL
	LD HL,(TELMODEM_API_RX_WAIT)
	EX (SP),HL
	RET
NET_SEND
	PUSH HL
	LD HL,(TELMODEM_API_NET_SEND)
	EX (SP),HL
	RET
DELAY_MS
	PUSH HL
	LD HL,(TELMODEM_API_DELAY)
	EX (SP),HL
	RET
TEST_FILL
	PUSH HL
	LD HL,(TELMODEM_API_TEST_FILL)
	EX (SP),HL
	RET
	ENDMODULE

; The imported engines retain their old abstract UART interface.  The native
; TCP stream has no UART flow-control register, so pause/resume/write are
; intentional no-ops; TX delegates to TELNET's bounded TCPX.SEND adapter.
	MODULE WIFI
UART_RX_PAUSE
UART_RX_RESUME
UART_WRITE
	XOR A
	RET
UART_TX_BUFFER
	JP MODEMAPI.NET_SEND
	ENDMODULE

	MODULE WCOMMON
CANCELLED EQU TELMODEM_CANCELLED
	ENDMODULE

; Keep the sibling engines source-compatible: their references resolve to
; fixed TELNET BSS fields or to the indirection wrappers above, never to a
; link-time address in the hot executable.
	MODULE MAIN
ZM_STATE_BASE	EQU TELMODEM_ZM_STATE_BASE
YM_STATE_BASE	EQU TELMODEM_YM_STATE_BASE
YM_C_PENDING	EQU TELMODEM_YM_C_PENDING
TRANSFER_STAGE	EQU TELMODEM_TRANSFER_STAGE
TN_PEER_SEEN	EQU RUNTIME_BASE + 0x77E
OUTPUT_BYTE	EQU MODEMAPI.OUTPUT_BYTE
PROCESS_RX_BYTE	EQU MODEMAPI.PROCESS_RX_BYTE
RX_DRAIN	EQU MODEMAPI.RX_DRAIN
RX_DRAIN_WAIT	EQU MODEMAPI.RX_DRAIN_WAIT
TEST_FILL	EQU MODEMAPI.TEST_FILL
	ENDMODULE

	MODULE UTIL
DELAY_MS	EQU MODEMAPI.DELAY_MS
	ENDMODULE

	INCLUDE "zmodem.asm"
	INCLUDE "ymodem.asm"

TELMODEM_IMAGE_END
	ASSERT TELMODEM_IMAGE_END <= TELMODEM_MAX_SIZE

	END
