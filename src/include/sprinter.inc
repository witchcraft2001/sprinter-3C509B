; Sprinter memory paging definitions.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_SPRINTER_INC
	DEFINE	_SPRINTER_INC

; Four independent MMU windows. PAGE3 is the one isa.asm's OPEN/CLOSE already
; use for the ISA window; PAGE0..PAGE2 are only needed by UNET_DLL's cold
; overlay (win0cold.asm), which stages its blob into WIN0 and never touches
; PAGE3 while the cold call runs.
PAGE0		EQU 0x82
PAGE1		EQU 0xA2
PAGE2		EQU 0xC2
PAGE3		EQU 0xE2

; Z80 address-space base of each window, for code that stages data through
; one of them (win0cold.asm's WIN3 staging, WIN0 remap).
PAGE0_ADDR	EQU 0x0000
PAGE1_ADDR	EQU 0x4000
PAGE2_ADDR	EQU 0x8000
PAGE3_ADDR	EQU 0xC000

PORT_SYSTEM	EQU 0x1FFD
PORT_ISA	EQU 0x9FBD
	ENDIF
