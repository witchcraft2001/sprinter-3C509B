; ======================================================
; win0cold.asm -- load and invoke "cold" code appended to UNET509B.DLL's
; own file, via a page mapped into MMU window 0.
;
; Ported from the BSD-3-Clause sprinter-rtl8019a sibling's WIN0COLD (same
; author); the mechanism is unchanged (DSS_GETMEM + BIOS_EMM_FN4 physical
; lookup, the file re-opened to find the trailing blob, a page staged over
; WIN3 before ISA is ever touched, PAGE0 remapped for the duration of each
; call). One behavioral change from the sibling, per this kit's own design
; decision: the sibling's RUN leaves the caller's stack live under WIN0
; while the cold code runs; ours does not assume WIN0 is ever safe for a
; stack (the DLL may load into WIN1 while the CALLER's own stack lives in
; WIN0), so RUN switches to the upper 128 bytes of the mapped cold page for
; the duration of the call. The sibling also never frees its allocated
; page (FINI does not exist for a load-once DLL there); this one adds FREE
; so a libman l_free does not leak a DSS_GETMEM block.
;
; UNET509B.DLL's own image is capped at the same hard libman byte budget
; the sibling has (see unet509b.asm's ASSERT). The actual protocol codecs
; (ipv4/tcp/udp/icmp/arp/ethernet -- see unet509b_cold.asm) have no
; DSS/BIOS/ISA dependency and operate purely on descriptor pointers, so
; they live in this separate blob appended to the .DLL file instead:
;
;   [normal L1 DLL: header + code image + reloc bitmap]
;   [2-byte LE length of the cold blob]
;   [cold blob bytes, assembled with ORG 0x0000]
;
; INIT (once, from F_NETINIT, idempotent):
;   1. DSS_GETMEM one page; BIOS_EMM_FN4 its physical byte (both RST
;      DSS/RST BIOS calls happen here, BEFORE anything touches WIN0 or
;      the ISA window).
;   2. Re-open this DLL's own file (exe-homedir first, bare name
;      fallback, since libman's vendored loader records no path a
;      re-opener could rely on).
;   3. Read the L1 header's file_size field (offset 2) -- for an
;      uncompressed image that is exactly the byte offset where our own
;      trailing data starts. Seek there, read the 2-byte length prefix,
;      then read that many bytes into the allocated page staged over
;      WIN3 (the one DSS-file-I/O target this codebase has already
;      proven safe while a block is mapped there: libman13.asm's own
;      l_load does exactly this). WIN3 is free to use here: this all
;      happens before NETDRV.INIT ever calls ISA.OPEN.
;   4. Close the file, restore WIN3 to whatever it held before.
;
; RUN (every cold invocation):
;   Sample IFF2, DI, save the caller's SP and switch to 0x4000,
;   save PAGE0 and write the cached physical byte, CALL the cold image's
;   entry point at offset 0, restore PAGE0, restore the caller's SP,
;   restore IFF2 (EI only if it was set).
;
;   The cold code touches nothing by absolute address: every buffer it
;   reads/writes is handed to it as a pointer in the COLD_CTX block (see
;   coldctx.inc) or in registers at call time. This is what lets one cold
;   blob work regardless of which window (WIN1 or WIN2) the DLL itself
;   was relocated into. The cold code must never touch DSS/BIOS (RST
;   0x10/RST 0x08 are both unreachable while PAGE0 holds the cold page)
;   and must never EI -- RUN restores interrupts itself on return.
;
; FREE (from FINI): DSS_FREEMEM the allocated block if INIT ever
; succeeded; idempotent, safe to call even if INIT was never run.
;
; Public API (INCLUDE "win0cold.asm" after the DLL BSS exists):
;
;   COLD.INIT
;       Out: CF=0 ready; CF=1 unavailable: A = the DSS error code if the
;            page allocation itself failed, else 0xFF (physical lookup,
;            reopen, header/seek/length/read failure). F_NETINIT stores A
;            in UNET_TCP_LAST and reports NERR_HW, so LASTERR reads
;            "st=01 nerr=01 tcp=FF" (or tcp=<DSS code>) for the session.
;            Per-stage codes were planned but do not fit the image budget.
;       Trashes A, BC, DE, HL, IX.
;
;   COLD.RUN
;       In:  A = cold function code (CFN_*, dispatched by the blob's own
;            offset-0 table); IX = pointer to that call's COLD_CTX/
;            descriptor block (meaning defined per function code); other
;            registers per that function's own contract.
;       Out: per that function's own contract.
;       Trashes nothing beyond what the specific cold function documents;
;       DI/EI, the stack switch and the WIN0 remap are invisible to the
;       caller. CF=1 without running anything if INIT never succeeded.
;
;   COLD.FREE
;       Releases the DSS_GETMEM block if one is held. Trashes A, C.
;
;       Interrupt contract matches isa.asm's ISA.OPEN/ISA.CLOSE (and for
;       the same reason: every current caller runs this while the ISA
;       window may be open, PAGE3 mapped to the card). RUN samples the
;       caller's real IFF2 before its own DI and restores exactly that
;       state afterward -- it must never unconditionally EI, or it would
;       re-enable interrupts out from under a still-open ISA window.
;
; SPDX-License-Identifier: BSD-3-Clause
; ======================================================

	IFNDEF	_WIN0COLD
	DEFINE	_WIN0COLD

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"

	MODULE	COLD

READY		DB 0			; 1 once INIT has loaded the blob
BLOCK_ID	DB 0xFF
PHYS_BYTE	DB 0

; ------------------------------------------------------
; INIT: see header comment.
; ------------------------------------------------------
INIT
	LD	A,(READY)
	OR	A
	RET	NZ			; idempotent: a repeated NETINIT must not
					; leak another DSS_GETMEM page
	LD	B,1
	LD	C,DSS_GETMEM
	RST	DSS
	RET	C
	LD	(BLOCK_ID),A
	LD	B,0
	LD	C,BIOS_EMM_FN4
	RST	BIOS
	JR	C,.free_block
	LD	(PHYS_BYTE),A
	CALL	.LOAD_BLOB
	JR	C,.free_block
	LD	A,1
	LD	(READY),A
	OR	A
	RET
.free_block
	LD	A,(BLOCK_ID)
	LD	C,DSS_FREEMEM
	RST	DSS
	LD	A,0xFF
	LD	(BLOCK_ID),A
	SCF
	RET

; ------------------------------------------------------
; .LOAD_BLOB: reopen our own file, find the trailing blob, copy it into
; the allocated page staged over WIN3. ISA is guaranteed closed here
; (INIT runs from F_NETINIT before NETDRV.INIT).
;   Out: CF=0 loaded; CF=1 file/format problem (the caller's .free_block
;        releases the page and reports A=0xFF).
; ------------------------------------------------------
.LOAD_BLOB
	CALL	.OPEN_SELF
	RET	C
	LD	(.FH),A
	; A freshly opened handle is already positioned at 0. L1 header:
	; the 2-byte "file_size" at offset 2 is the byte offset where our
	; own trailing data starts (uncompressed image: header + code +
	; reloc bitmap together equal exactly file_size).
	LD	HL,.HDRBUF
	LD	DE,8
	LD	C,DSS_READ_FILE
	RST	DSS			; A still = handle from .OPEN_SELF's return
	JR	C,.close_fail
	LD	IX,(.HDRBUF+2)		; file_size = tail offset (low word)
	LD	A,(.FH)
	LD	B,SEEK_SET
	LD	HL,0			; offset high word
	LD	C,DSS_MOVE_FP
	RST	DSS
	JR	C,.close_fail
	; 2-byte LE length prefix of the cold blob.
	LD	A,(.FH)
	LD	HL,.HDRBUF
	LD	DE,2
	LD	C,DSS_READ_FILE
	RST	DSS
	JR	C,.close_fail
	LD	HL,(.HDRBUF)
	LD	A,H
	OR	L
	JR	Z,.close_fail		; zero-length: nothing to run
	LD	(.BLOBLEN),HL
	; Stage the page over WIN3, save+restore its prior mapping.
	LD	BC,PAGE3
	IN	A,(C)
	LD	(.SAVE_WIN3),A
	LD	A,(PHYS_BYTE)
	LD	BC,PAGE3
	OUT	(C),A
	LD	A,(.FH)
	LD	HL,PAGE3_ADDR
	LD	DE,(.BLOBLEN)
	LD	C,DSS_READ_FILE
	RST	DSS
	PUSH	AF
	LD	A,(.SAVE_WIN3)
	LD	BC,PAGE3
	OUT	(C),A
	POP	AF
	JR	C,.close_fail
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	OR	A
	RET
.close_fail
	LD	A,(.FH)
	LD	C,DSS_CLOSE_FILE
	RST	DSS
	SCF
	RET
.FH		DB 0
.HDRBUF		DS 8
.BLOBLEN	DW 0
.SAVE_WIN3	DB 0

; ------------------------------------------------------
; .OPEN_SELF: try "<exe_home>\UNET509B.DLL", then the bare name -- the
; same tolerance NETCFG's own path loader applies, since libman's
; vendored loader records no path a re-opener could rely on.
;   Out: CF=0 -> A = handle; CF=1 -> both attempts failed.
; ------------------------------------------------------
.OPEN_SELF
	LD	HL,.PATH
	LD	B,APPINFO_EXE_HOMEDIR
	LD	C,DSS_APPINFO
	RST	DSS
	JR	C,.bare
	LD	HL,.PATH
	LD	B,64
.find_end
	LD	A,(HL)
	OR	A
	JR	Z,.have_end
	INC	HL
	DJNZ	.find_end
	JR	.bare			; overlong/malformed
.have_end
	LD	A,(.PATH)
	OR	A
	JR	Z,.bare			; empty result
	DEC	HL
	LD	A,(HL)
	INC	HL
	CP	92			; '\'
	JR	Z,.append
	CP	'/'
	JR	Z,.append
	LD	(HL),92
	INC	HL
.append
	EX	DE,HL
	LD	HL,.NAME
	CALL	.STRCPY
	LD	A,FA_READONLY
	LD	HL,.PATH
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET	NC
.bare
	LD	A,FA_READONLY
	LD	HL,.NAME
	LD	C,DSS_OPEN_FILE
	RST	DSS
	RET
.STRCPY
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	OR	A
	JR	NZ,.STRCPY
	RET
.NAME		DB "UNET509B.DLL",0
.PATH		DS 65

; ------------------------------------------------------
; FREE: release the allocated page, if any. Safe to call whether or not
; INIT ever succeeded (FINI calls this unconditionally).
; ------------------------------------------------------
FREE
	LD	A,(BLOCK_ID)
	CP	0xFF
	RET	Z
	LD	C,DSS_FREEMEM
	RST	DSS
	LD	A,0xFF
	LD	(BLOCK_ID),A
	XOR	A
	LD	(READY),A
	RET

; ------------------------------------------------------
; RUN: see header comment's "RUN" entry.
; ------------------------------------------------------
RUN
	PUSH	AF			; preserve the caller's function code
	LD	A,(READY)
	OR	A
	JR	NZ,.go
	POP	AF
	SCF
	RET
.go
	POP	AF
	EX	AF,AF'			; park the function code during IFF sampling
	; Sample the caller's real IFF2 BEFORE the DI below, mirroring
	; isa.asm's ISA.OPEN (NMOS erratum: a maskable interrupt can land
	; mid "LD A,I" and misreport P/V once; if it did, its handler has
	; already returned with EI, so a second read correctly sees 1).
	LD	A,I
	JP	PE,.IFF_ON
	LD	A,I
	JP	PE,.IFF_ON
	XOR	A
	JR	.IFF_SAMPLED
.IFF_ON
	LD	A,1
.IFF_SAMPLED
	LD	(.SAVE_IFF),A
	DI
	; Save the caller stack while it is still mapped. The register bank, not a
	; PUSH/POP pair, carries BC across the PAGE0 write: the caller's stack may
	; itself be in WIN0 and becomes inaccessible as soon as that write lands.
	; The real cold stack is in the upper 128 bytes of the cold page, above the
	; enforced 0x3F80 blob boundary.
	; The DLL itself lives in WIN1 or WIN2, but the caller's own stack may live
	; in WIN0, which is about to be repointed at the cold page.
	LD	(.SAVE_SP),SP
	; BC is a live pass-through register in both directions, so the
	; PAGE0 port loads below must not leak into or out of the cold call.
	EXX
	LD	BC,PAGE0
	IN	A,(C)
	LD	(.SAVE_PAGE0),A
	LD	A,(PHYS_BYTE)
	OUT	(C),A
	EXX
	LD	SP,0x4000
	EX	AF,AF'
	CALL	0x0000
	; Preserve every returned register in the alternate bank while PAGE0 is
	; restored. Cold code may use the alternate bank internally, but only its
	; main-bank outputs are part of the public contract at this boundary.
	EX	AF,AF'
	EXX
	LD	A,(.SAVE_PAGE0)
	LD	BC,PAGE0
	OUT	(C),A
	LD	SP,(.SAVE_SP)
	EXX
	EX	AF,AF'
	PUSH	AF
	LD	A,(.SAVE_IFF)
	OR	A
	JR	Z,.no_ei
	EI
.no_ei
	POP	AF
	RET
.SAVE_PAGE0	DB 0
.SAVE_IFF	DB 0
.SAVE_SP	DW 0

	ENDMODULE
	ENDIF
