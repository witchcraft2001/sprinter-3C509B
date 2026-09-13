; =====================================================================
; TELNET.EXE stage-1 PRELOAD loader, assembled at 0x8100.
;
; This is the Sprinter Fido Editor loader layout, adapted only for TELNET's
; three blobs: WIN0 entry code, resident WIN1 code and one modem overlay.
; DSS leaves the EXE open and stores its handle at PSP-3; all data following
; this preloaded blob is therefore read through that inherited handle.
; SPDX-License-Identifier: BSD-3-Clause
; =====================================================================

	DEVICE NOSLOT64K

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"

OVR_COUNT	EQU 1

	ORG 0x8100

LOADER_ENTRY
	DI
	LD SP,0xBFFF
	LD (PSP_PTR),IX
	LD A,(IX-3)
	LD (HANDLE),A
	IN A,(PAGE0)
	LD (DSS_PAGE),A

	; Size header: {DW win0_len, DW win1_len, DB overlay_count}.
	LD HL,WIN0_LEN
	LD DE,5
	CALL READ_FULL

	LD A,(N_OVR)
	OR A
	JR Z,.NO_OVERLAY_LENGTHS
	ADD A,A
	LD E,A
	LD D,0
	LD HL,OVERLAY_LENGTHS
	CALL READ_FULL
.NO_OVERLAY_LENGTHS

	; WIN0 blob is linked at 0x0180 and staged through WIN1:0x4180.
	CALL GETMEM1
	JP C,FAIL
	LD (P0),A
	OUT (PAGE1),A
	LD HL,0x4180
	LD DE,(WIN0_LEN)
	CALL READ_FULL

	; Resident program page occupies WIN1:0x4000..0x7fff.
	CALL GETMEM1
	JP C,FAIL
	LD (P1),A
	OUT (PAGE1),A
	LD HL,0x4000
	LD DE,(WIN1_LEN)
	CALL READ_FULL

	; Load each overlay at page offset zero through WIN1.
	XOR A
	LD (OVERLAY_INDEX),A
.OVERLAY_LOOP
	LD A,(OVERLAY_INDEX)
	LD B,A
	LD A,(N_OVR)
	CP B
	JR Z,.OVERLAYS_DONE
	CALL GETMEM1
	JP C,FAIL
	LD (CURRENT_PAGE),A
	OUT (PAGE1),A
	LD A,(OVERLAY_INDEX)
	ADD A,A
	LD E,A
	LD D,0
	LD HL,OVERLAY_LENGTHS
	ADD HL,DE
	LD E,(HL)
	INC HL
	LD D,(HL)
	LD HL,0x4000
	CALL READ_FULL
	LD A,(OVERLAY_INDEX)
	LD E,A
	LD D,0
	LD HL,OVERLAY_PAGES
	ADD HL,DE
	LD A,(CURRENT_PAGE)
	LD (HL),A
	LD A,(OVERLAY_INDEX)
	INC A
	LD (OVERLAY_INDEX),A
	JR .OVERLAY_LOOP
.OVERLAYS_DONE

	LD A,(HANDLE)
	LD C,DSS_CLOSE_FILE
	RST DSS

	; Boot parameters at P0:0x0040, exactly as in Fido Editor.
	LD A,(P0)
	OUT (PAGE1),A
	LD A,(DSS_PAGE)
	LD (0x4040),A
	LD A,(P0)
	LD (0x4041),A
	LD A,(P1)
	LD (0x4042),A
	LD A,(N_OVR)
	LD (0x4043),A
	LD A,(N_OVR)
	OR A
	JR Z,.NO_OVERLAY_COPY
	LD B,A
	LD HL,OVERLAY_PAGES
	LD DE,0x4044
.OVERLAY_COPY
	LD A,(HL)
	LD (DE),A
	INC HL
	INC DE
	DJNZ .OVERLAY_COPY
.NO_OVERLAY_COPY

	; Preserve the complete DSS command-line block at P0:0x0080.
	LD HL,(PSP_PTR)
	LD DE,0x4080
	LD BC,128
	LDIR

	DI
	XOR A
	OUT (0x3C),A
	LD A,(P0)
	OUT (PAGE0),A
	LD A,(P1)
	OUT (PAGE1),A
	LD HL,0x0180
	JP (HL)

; Allocate one 16 KiB page and resolve its physical page number.
; Out: A=physical page, CF=0; CF=1 on allocation failure.
GETMEM1
	LD B,1
	LD C,DSS_GETMEM
	RST DSS
	RET C
	LD HL,PAGE_BUFFER
	LD C,BIOS_EMM_FN5
	RST BIOS
	LD A,(PAGE_BUFFER)
	OR A
	RET

; Read exactly DE bytes from HANDLE into HL. DSS may return one cluster per
; call, hence the loop. This routine intentionally matches Fido Editor.
READ_FULL
	LD (READ_BUFFER),HL
	LD (READ_COUNT),DE
.LOOP
	LD HL,(READ_COUNT)
	LD A,H
	OR L
	RET Z
	LD DE,(READ_COUNT)
	LD HL,(READ_BUFFER)
	LD A,(HANDLE)
	LD C,DSS_READ_FILE
	RST DSS
	LD A,D
	OR E
	RET Z
	LD HL,(READ_BUFFER)
	ADD HL,DE
	LD (READ_BUFFER),HL
	LD HL,(READ_COUNT)
	OR A
	SBC HL,DE
	LD (READ_COUNT),HL
	JR .LOOP

FAIL
	LD HL,MSG_NOMEM
	LD C,DSS_PCHARS
	RST DSS
	LD B,1
	LD C,DSS_EXIT
	RST DSS

MSG_NOMEM	DB "TELNET: not enough memory",13,10,0

PSP_PTR		DW 0
HANDLE		DB 0
DSS_PAGE	DB 0
P0		DB 0
P1		DB 0
WIN0_LEN	DW 0
WIN1_LEN	DW 0
N_OVR		DB 0
OVERLAY_LENGTHS DS OVR_COUNT * 2
OVERLAY_PAGES	DS OVR_COUNT
PAGE_BUFFER	DS 16
OVERLAY_INDEX	DB 0
CURRENT_PAGE	DB 0
READ_BUFFER	DW 0
READ_COUNT	DW 0
