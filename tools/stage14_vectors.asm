; Executable UNET509B.DLL entry-point vectors for z88dk-ticks.
; SPDX-License-Identifier: BSD-3-Clause
;
; tools/test-stage14-asm.sh assembles this file three times around the
; SHIPPED build/UNET509B.DLL, relocated by an independent re-implementation
; of libman13's own `remake` loop (header at DLL_BASE, code at DLL_BASE+0x20,
; dispatch at DLL_BASE+0x20+3*fn):
;
;   DLL_BASE=0x4000 VEC_BASE=0x8000            DLL in WIN1, consumer in WIN2
;   DLL_BASE=0x8000 VEC_BASE=0x4000            DLL in WIN2, consumer in WIN1
;   DLL_BASE=0xC000 VEC_BASE=0x4000 WIN3_REFUSAL   INIT must refuse window 3
;
; Only entry points that need neither the card, the cold overlay nor real
; DSS services are exercised: the RST 0x10 stub below answers "no such
; variable" to every environment lookup, which is exactly the state of a
; machine where NETCFG/IFUP never ran. What this proves without hardware:
; the export table and calling convention, CF=0 on every return, the
; pre-NETINIT status codes, the caller-buffer window rules from both
; possible DLL windows, GETINFO/LASTERR text (which must not depend on the
; overlay), the in-image BSS canary, and that no call scribbles on the
; consumer's own window.

	DEVICE NOSLOT64K
	INCLUDE "unet.inc"
	INCLUDE "tcpctx.inc"

TEST_RESULT	EQU 0x3F00		; first failing case number, 0 = all passed
TEST_COMPLETE	EQU 0x3F01		; 0xA5 once TEST_DONE was reached
TEST_CASE	EQU 0x3F02
STACK_TOP	EQU 0x3E00
BUF		EQU VEC_BASE + 0x1000	; caller buffer, in the consumer's window
BUF_LEN		EQU 64
PATTERN		EQU VEC_BASE + 0x2000	; must survive every call untouched
PATTERN_LEN	EQU 0x2000
PATTERN_BYTE	EQU 0x5A

	MACRO ENTRY fn
	CALL	DLL_BASE + 0x20 + 3*fn
	ENDM

	MACRO CASE n
	LD	A,n
	LD	(TEST_CASE),A
	ENDM

	; Every UNET call except INIT must come back with CF=0 and A=status.
	MACRO EXPECT_A value
	JP	C,FAIL
	CP	value
	JP	NZ,FAIL
	ENDM

	MACRO EXPECT_DE value
	LD	HL,value
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	ENDM

	MACRO EXPECT_BUF label
	LD	HL,BUF
	LD	DE,label
	CALL	STRCMP
	JP	NZ,FAIL
	ENDM

	ORG	0x0008
	SCF				; BIOS: must never be reached from here
	RET
	ORG	0x0010
	XOR	A			; DSS: every ENVIRON lookup answers "absent"
	RET

	ORG	DLL_BASE
	INCBIN	"dll_image.bin"

	ORG	VEC_BASE
TEST_START
	LD	SP,STACK_TOP
	LD	A,0xFF
	LD	(TEST_RESULT),A
	XOR	A
	LD	(TEST_COMPLETE),A

	IFDEF	WIN3_REFUSAL
	CASE	1			; INIT refuses the ISA aperture
	ENTRY	UNET_FN_INIT
	JP	NC,FAIL
	CP	NERR_HW
	JP	NZ,FAIL
	JP	PASS
	ELSE

	LD	HL,PATTERN
	LD	DE,PATTERN+1
	LD	BC,PATTERN_LEN-1
	LD	(HL),PATTERN_BYTE
	LDIR

	CASE	1			; INIT accepts WIN1/WIN2
	ENTRY	UNET_FN_INIT
	EXPECT_A 0

	CASE	2			; GETCAPS: full-parity mask, ABI 1.0
	ENTRY	UNET_FN_GETCAPS
	EXPECT_A 0
	EXPECT_DE 0x023F
	PUSH	IX
	POP	DE
	EXPECT_DE UNET_ABI_VERSION

	CASE	42			; before the first failure LASTERR is live
	LD	A,1
	LD	(DLL_BASE + 0x20 + STAGE_OFF),A
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_LASTERR
	EXPECT_A 0
	EXPECT_BUF LASTERR_LIVE1

	CASE	43			; a second healthy poll sees the new stage
	LD	A,2
	LD	(DLL_BASE + 0x20 + STAGE_OFF),A
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_LASTERR
	EXPECT_A 0
	EXPECT_BUF LASTERR_LIVE2

	CASE	3			; STATUS(0xFF) with no NET_IP/NET_MAC published
	LD	A,0xFF
	ENTRY	UNET_FN_STATUS
	EXPECT_A NERR_NONET
	EXPECT_DE 0

	CASE	4			; LASTERR: exact fixed-layout text after that
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_LASTERR
	EXPECT_A 0
	EXPECT_BUF LASTERR_FULL

	CASE	5			; LASTERR truncates to max-1 chars plus NUL
	LD	DE,BUF
	LD	IX,10
	ENTRY	UNET_FN_LASTERR
	EXPECT_A 0
	EXPECT_BUF LASTERR_SHORT

	CASE	6			; LASTERR max=0: no room for the NUL
	LD	DE,BUF
	LD	IX,0
	ENTRY	UNET_FN_LASTERR
	EXPECT_A NERR_PARAM

	CASE	7			; GETINFO backend tag
	LD	A,UNET_IF_BACKEND
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_GETINFO
	EXPECT_A 0
	EXPECT_BUF TAG_509B

	CASE	8			; GETINFO truncation
	LD	A,UNET_IF_BACKEND
	LD	DE,BUF
	LD	IX,3
	ENTRY	UNET_FN_GETINFO
	EXPECT_A 0
	EXPECT_BUF TAG_50

	CASE	9			; GETINFO max=0
	LD	A,UNET_IF_BACKEND
	LD	DE,BUF
	LD	IX,0
	ENTRY	UNET_FN_GETINFO
	EXPECT_A NERR_PARAM

	CASE	10			; buffer inside the DLL's own window
	LD	A,UNET_IF_BACKEND
	LD	DE,DLL_BASE + 0x0100
	LD	IX,16
	ENTRY	UNET_FN_GETINFO
	EXPECT_A NERR_PARAM

	CASE	11			; buffer in window 3 (ISA aperture)
	LD	A,UNET_IF_BACKEND
	LD	DE,0xC000
	LD	IX,16
	ENTRY	UNET_FN_GETINFO
	EXPECT_A NERR_PARAM

	CASE	12			; buffer starting outside, ending inside the DLL window
	LD	A,UNET_IF_BACKEND
	LD	DE,DLL_BASE - 8
	LD	IX,16
	ENTRY	UNET_FN_GETINFO
	EXPECT_A NERR_PARAM

	CASE	13			; SSID: no Wi-Fi equivalent -> empty string
	LD	A,UNET_IF_SSID
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_GETINFO
	EXPECT_A 0
	EXPECT_BUF EMPTY

	CASE	14			; NET_IP not published -> empty string
	LD	A,UNET_IF_IP
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_GETINFO
	EXPECT_A 0
	EXPECT_BUF EMPTY

	CASE	15			; unknown field id -> empty string
	LD	A,13
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_GETINFO
	EXPECT_A 0
	EXPECT_BUF EMPTY

	CASE	16			; STATUS on both closed channels
	XOR	A
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE 0
	LD	A,1
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE 0

	CASE	17			; STATUS channel 2 (MULTICHAN means exactly two)
	LD	A,2
	ENTRY	UNET_FN_STATUS
	EXPECT_A NERR_PARAM

	CASE	18			; SETOPT RXTRIG: valid id, no hardware for it
	LD	A,UNET_OPT_RXTRIG
	LD	DE,4
	ENTRY	UNET_FN_SETOPT
	EXPECT_A NERR_NOTSUP

	CASE	19			; SETOPT unknown id
	LD	A,9
	LD	DE,1
	ENTRY	UNET_FN_SETOPT
	EXPECT_A NERR_PARAM

	CASE	20			; SETOPT CANCELKEYS / SENDSLICE accept on and off
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,1
	ENTRY	UNET_FN_SETOPT
	EXPECT_A 0
	LD	A,UNET_OPT_SENDSLICE
	LD	DE,10
	ENTRY	UNET_FN_SETOPT
	EXPECT_A 0
	LD	A,UNET_OPT_SENDSLICE
	LD	DE,0
	ENTRY	UNET_FN_SETOPT
	EXPECT_A 0
	LD	A,UNET_OPT_CANCELKEYS
	LD	DE,0
	ENTRY	UNET_FN_SETOPT
	EXPECT_A 0

	CASE	21			; RXPAUSE / RXRESUME: no-ops, even before NETINIT
	ENTRY	UNET_FN_RXPAUSE
	EXPECT_A 0
	ENTRY	UNET_FN_RXRESUME
	EXPECT_A 0

	CASE	22			; reserved slots 20..23
	ENTRY	UNET_FN_RESERVED20
	EXPECT_A NERR_NOTSUP
	ENTRY	UNET_FN_RESERVED21
	EXPECT_A NERR_NOTSUP
	ENTRY	UNET_FN_RESERVED22
	EXPECT_A NERR_NOTSUP
	ENTRY	UNET_FN_RESERVED23
	EXPECT_A NERR_NOTSUP

	CASE	23			; CONNECT channel 2
	LD	A,2
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	ENTRY	UNET_FN_CONNECT
	EXPECT_A NERR_PARAM

	CASE	24			; CONNECT before NETINIT
	XOR	A
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	ENTRY	UNET_FN_CONNECT
	EXPECT_A NERR_STATE

	CASE	25			; SEND on a closed channel
	XOR	A
	LD	DE,BUF
	LD	IX,5
	ENTRY	UNET_FN_SEND
	EXPECT_A NERR_STATE

	CASE	26			; RECV on a closed channel
	XOR	A
	LD	DE,BUF
	LD	IX,BUF_LEN
	LD	IY,0
	ENTRY	UNET_FN_RECV
	EXPECT_A NERR_STATE

	CASE	27			; CLOSE is idempotent on a closed channel
	XOR	A
	ENTRY	UNET_FN_CLOSE
	EXPECT_A 0
	; The successful CLOSE changed the live stage to 05, but the snapshot
	; still describes case 26's failed RECV (stage 04/NERR_STATE).
	LD	DE,BUF
	LD	IX,BUF_LEN
	ENTRY	UNET_FN_LASTERR
	EXPECT_A 0
	EXPECT_BUF LASTERR_FROZEN

	CASE	28			; UDPOPEN before NETINIT
	XOR	A
	LD	DE,HOST_STR
	LD	IX,PORT_STR
	LD	IY,0
	ENTRY	UNET_FN_UDPOPEN
	EXPECT_A NERR_STATE

	CASE	29			; RESOLVE before NETINIT (parsers live in the overlay)
	LD	DE,HOST_STR
	LD	IX,BUF
	ENTRY	UNET_FN_RESOLVE
	EXPECT_A NERR_STATE

	CASE	30			; PING before NETINIT
	LD	DE,HOST_STR
	LD	IY,1000
	ENTRY	UNET_FN_PING
	EXPECT_A NERR_STATE

	CASE	31			; LISTEN port 0
	XOR	A
	LD	DE,0
	ENTRY	UNET_FN_LISTEN
	EXPECT_A NERR_PARAM

	CASE	32			; LISTEN before NETINIT
	XOR	A
	LD	DE,9000
	ENTRY	UNET_FN_LISTEN
	EXPECT_A NERR_STATE

	CASE	33			; LISTEN channel 5
	LD	A,5
	LD	DE,9000
	ENTRY	UNET_FN_LISTEN
	EXPECT_A NERR_PARAM

	CASE	34			; UNLISTEN with nothing listening (INIT unarmed it)
	XOR	A
	ENTRY	UNET_FN_UNLISTEN
	EXPECT_A NERR_STATE

	CASE	35			; NETDONE is idempotent
	ENTRY	UNET_FN_NETDONE
	EXPECT_A 0

	CASE	36			; FINI: teardown of a never-initialised image
	ENTRY	UNET_FN_FINI
	EXPECT_A 0

	CASE	39			; STATUS reports buffered data (UNET_ST_RXPEND)
	; F_STATUS never touches hardware, so the pend bit can be exercised
	; without a peer: mark a channel connected and put a byte count where
	; TCPX leaves a segment that landed while no RECV was waiting. Without
	; this bit an app cannot tell "nothing arrived" from "a reply is
	; already sitting in the backend", and a RECV timeout looks the same.
	LD	A,1
	LD	(DLL_BASE + 0x20 + CH_STATE_OFF + 1),A
	LD	HL,0
	LD	(DLL_BASE + 0x20 + PEND1_OFF),HL
	LD	A,1
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE UNET_ST_CONN
	LD	HL,536
	LD	(DLL_BASE + 0x20 + PEND1_OFF),HL
	LD	A,1
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE UNET_ST_CONN|UNET_ST_RXPEND
	; the probe must read the context the caller asked about, not a fixed one
	XOR	A
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE 0
	; a UDP channel (state 2) has no TCP pend slot of its own, so a stale
	; count in the TCP context must not leak into its status
	LD	A,2
	LD	(DLL_BASE + 0x20 + CH_STATE_OFF + 1),A
	LD	A,1
	ENTRY	UNET_FN_STATUS
	EXPECT_A 0
	EXPECT_DE UNET_ST_CONN
	XOR	A			; leave the image as the later cases expect
	LD	(DLL_BASE + 0x20 + CH_STATE_OFF + 1),A
	LD	HL,0
	LD	(DLL_BASE + 0x20 + PEND1_OFF),HL

	CASE	40			; a host argument in window 0 is refused
	; The resolver reads the caller's host text in place, and part of it
	; runs as a cold call with the overlay mapped over window 0 -- a
	; pointer there would read the blob, not the name. NETINIT is faked
	; so the state check ahead of the window check is out of the way; the
	; refusal happens before any hardware access.
	LD	A,1
	LD	(DLL_BASE + 0x20 + INITED_OFF),A
	LD	DE,0x0100		; window 0
	LD	IX,BUF
	ENTRY	UNET_FN_RESOLVE
	EXPECT_A NERR_PARAM
	LD	DE,0x0100
	LD	IY,1000
	ENTRY	UNET_FN_PING
	EXPECT_A NERR_PARAM
	XOR	A
	LD	(DLL_BASE + 0x20 + INITED_OFF),A

	CASE	41			; partial caller buffer drains only what fits
	; Seed channel 1's durable pending slot without touching the card. RECV
	; must return exactly the five-byte caller capacity, advance pending_off,
	; retain the other five bytes and leave the guard byte untouched.
	LD	A,1
	LD	(DLL_BASE + 0x20 + CH_STATE_OFF + 1),A
	LD	HL,0
	LD	(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_OFF),HL
	LD	HL,10
	LD	(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_LEN),HL
	LD	HL,DLL_BASE + 0x20 + PENDING1_DATA_OFF
	LD	DE,SMALL_PENDING
	LD	BC,5
.seed_small
	LD	A,(DE)
	LD	(HL),A
	INC	DE
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.seed_small
	LD	A,0xA6
	LD	(BUF+5),A
	LD	A,1
	LD	DE,BUF
	LD	IX,5
	LD	IY,0
	ENTRY	UNET_FN_RECV
	EXPECT_A 0
	EXPECT_DE 5
	LD	HL,BUF
	LD	DE,SMALL_PENDING
	LD	B,5
.check_small
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAIL
	INC	DE
	INC	HL
	DJNZ	.check_small
	LD	A,(BUF+5)
	CP	0xA6
	JP	NZ,FAIL
	LD	HL,(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_OFF)
	LD	DE,5
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	LD	HL,(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_LEN)
	LD	DE,5
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	XOR	A
	LD	(DLL_BASE + 0x20 + CH_STATE_OFF + 1),A
	LD	HL,0
	LD	(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_OFF),HL
	LD	(DLL_BASE + 0x20 + CTX1_OFF + CTX_PENDING_LEN),HL

	CASE	37			; in-image BSS canary
	LD	A,(DLL_BASE + 0x20 + CANARY_OFF)
	CP	0xA5
	JP	NZ,FAIL

	CASE	38			; the consumer's own window is untouched
	LD	HL,PATTERN
	LD	BC,PATTERN_LEN
.check
	LD	A,(HL)
	CP	PATTERN_BYTE
	JP	NZ,FAIL
	CPI
	JP	PE,.check

	ENDIF

PASS
	XOR	A
	LD	(TEST_RESULT),A
	JR	MARK_COMPLETE
FAIL
	LD	A,(TEST_CASE)
	LD	(TEST_RESULT),A
MARK_COMPLETE
	LD	A,0xA5
	LD	(TEST_COMPLETE),A
TEST_DONE				; z88dk-ticks stops when PC reaches this address
	JR	TEST_DONE

; STRCMP: Z if the ASCIIZ strings at HL and DE are identical.
STRCMP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	STRCMP

LASTERR_LIVE1	DB "509B hw=0 st=01 nerr=00 tcp=00 el3=00/0000",0
LASTERR_LIVE2	DB "509B hw=0 st=02 nerr=00 tcp=00 el3=00/0000",0
LASTERR_FULL	DB "509B hw=0 st=02 nerr=02 tcp=00 el3=00/0000",0
LASTERR_SHORT	DB "509B hw=0",0
LASTERR_FROZEN	DB "509B hw=0 st=04 nerr=0B tcp=00 el3=00/0000",0
TAG_509B	DB "509B",0
TAG_50		DB "50",0
EMPTY		DB 0
HOST_STR	DB "192.168.7.44",0
PORT_STR	DB "80",0
SMALL_PENDING	DB "small"

	SAVEBIN "vectors.bin",0,0x10000
