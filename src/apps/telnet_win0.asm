; =====================================================================
; TELNET WIN0 entry blob, loaded by telnet_loader.asm at page offset 0x0180.
; It copies the Fido-style boot record to resident WIN2 state, installs the
; private WIN0 RST vectors and enters the resident terminal in WIN1.
; SPDX-License-Identifier: BSD-3-Clause
; =====================================================================

	DEVICE NOSLOT64K

	DEFINE RUNTIME_BASE 0xB000
	INCLUDE "telmodem.inc"

	ORG 0x0180

WIN0_ENTRY
	LD A,(0x0040)
	LD (TELNET_SYS_DSS_PAGE),A
	LD (TELMODEM_BOOT_DSS_PAGE),A
	LD A,(0x0041)
	LD (TELNET_SYS_P0_PAGE),A
	LD A,(0x0042)
	LD (TELNET_SYS_P1_PAGE),A
	LD A,(0x0044)
	LD (TELMODEM_BOOT_PHYS_PAGE),A
	XOR A
	LD (TELMODEM_BOOT_BLOCK_ID),A
	LD A,0xA5
	LD (TELMODEM_BOOT_VALID),A

	LD HL,0x0008
	LD DE,TELNET_SYS_BIOS_TRAMP
	CALL INSTALL_VECTOR
	LD HL,0x0010
	LD DE,TELNET_SYS_DSS_TRAMP
	CALL INSTALL_VECTOR
	LD HL,0x0030
	LD DE,TELNET_SYS_MOUSE_TRAMP
	CALL INSTALL_VECTOR
	LD HL,0x0038
	LD DE,TELNET_SYS_INT_TRAMP
	CALL INSTALL_VECTOR

	LD IX,0x0080
	LD SP,0xBFF0
	EI
	JP 0x4100

INSTALL_VECTOR
	LD (HL),0xC3
	INC HL
	LD (HL),E
	INC HL
	LD (HL),D
	RET
