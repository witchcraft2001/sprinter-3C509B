; ======================================================
; unet509b_cold.asm -- protocol codec code appended to UNET509B.DLL's own
; file as a trailing blob (see src/lib/win0cold.asm for the loader and
; per-call WIN0 mapping). Assembled COMPLETELY SEPARATELY from
; unet509b.asm (raw, ORG 0x0000, no L1 header, no relocation bitmap): it
; is never linked with the hot image and has no way to know which window
; (WIN1 or WIN2) the hot image was relocated into at load time. Every
; routine below is therefore a pure function of its register arguments
; plus, where noted, the COLD_CTX pointer block (src/include/coldctx.inc)
; the hot shim fills in once at NETINIT -- NEVER a fixed address of the
; hot image or of memory.inc's normal RUNTIME_BASE-relative fields.
;
; What lives here vs what stays hot: ethernet.asm, ipv4.asm and tcp.asm
; are backend-neutral codecs that already take every buffer as a
; descriptor pointer passed in a register (verified: grepping their
; bodies against every memory.inc-derived symbol name found zero
; matches), so they are INCLUDEd below completely unmodified -- the only
; thing making them "cold" is which file they end up assembled into.
; arp.asm's BUILD_REQUEST/BUILD_REPLY/PARSE are different: the hot
; original reads/writes NET_LOCAL_IP/NET_TARGET_IP/NET_NEXT_HOP_IP/
; NET_RESULT_MAC/NETDRV_STATION_MAC directly, which are real addresses in
; the HOT image's own BSS. Those three routines are reimplemented below
; (byte-for-byte the same frame layout) reading the same fields through
; COLD_CTX pointers instead; arp.asm's own copies become 11-byte
; trampolines into here (see arp.asm's IFDEF UNET_DLL branch).
; SELECT_NEXT_HOP/DEST_FOR_US/the ARP cache stay hot (SELECT_NEXT_HOP is
; used by route resolution outside of any single frame exchange; the
; cache is disabled for this DLL entirely -- one ARP exchange per
; CONNECT/UDPOPEN/RESOLVE/PING, decision recorded in the plan -- and
; DEST_FOR_US had exactly one caller, ARP_PARSE below, so it moved here
; with it instead of staying as unreferenced hot code).
;
; Dispatch: win0cold.asm's COLD.RUN always CALLs address 0x0000 with
; A = the CFN_* function code it was given and every other register
; exactly as the hot trampoline set it up (win0cold.asm's RUN never
; touches BC/DE/HL/IX itself). DISPATCH below is that fixed entry.
;
; unet509b_bss.inc's BSS_* offsets and DLL_BSS=0 below exist only so this
; file's own (and ipv4.asm/tcp.asm/arp support code's) `INCLUDE
; "memory.inc"` resolves to something -- nothing in the included codecs
; references DLL_BSS or any BSS_* field by address; see coldctx.inc and
; unet509b_bss.inc's own header comments.
;
; SPDX-License-Identifier: BSD-3-Clause
; ======================================================

	DEFINE	UNET_DLL
	DEFINE	STAGE12_LAYOUT
	DEFINE	STAGE13_LAYOUT
	DEFINE	FAST_DATAPATH

; netdrv.inc's NETDRV_ERR_LINK_DOWN aliases el3.inc's EL3_ERR_LINK_TIMEOUT;
; el3.inc itself is hot-only (touches hardware, never linked into the cold
; blob), and nothing here reads NETDRV_ERR_LINK_DOWN, so this exists only
; to let netdrv.inc's own EQU resolve. Value matches el3.inc's for the
; unlikely case anything ever compares against it.
EL3_ERR_LINK_TIMEOUT	EQU 20
; el3.inc constants PARSE_HW's cold BASE_ENCODE copy needs; same reasoning
; as EL3_ERR_LINK_TIMEOUT above (el3.inc itself stays hot-only).
EL3_BASE_MIN		EQU 0x0200
EL3_BASE_MAX		EQU 0x03E0
EL3_ERR_BASE		EQU 6
EL3_OK			EQU 0
EL3_ERR_NOT_FOUND	EQU 3
EL3_ERR_CHECKSUM	EQU 5
EL3_ERR_RX_TIMEOUT	EQU 14
EL3_MFG_3COM		EQU 0x6D50
EL3_PRODUCT_3C509B_TPO EQU 0x9550

	INCLUDE "coldctx.inc"
	INCLUDE "tcpctx.inc"
	INCLUDE "unet.inc"		; NERR_* only (frozen, pure constants)

DLL_BSS	EQU 0
	INCLUDE "unet509b_bss.inc"
RUNTIME_BASE	EQU DLL_BSS + BSS_RT	; unet509b.asm defines this before memory.inc too
S9_ENV_BUFFER	EQU DLL_BSS + BSS_RX	; ditto -- see unet509b.asm's own copy
	INCLUDE "memory.inc"		; UNET_DLL -> memory_dll.inc; unused here

	ORG	0x0000

; ------------------------------------------------------
; DISPATCH: the cold image's only entry point. An out-of-range or not-yet
; -implemented code is a defensive no-op (RET with whatever the caller
; already had in A/CF -- every real handler sets its own status).
; ------------------------------------------------------
DISPATCH
	CP	CFN_COUNT
	JR	NC,.UNKNOWN
	; HL and DE are argument registers for nearly every cold function (a
	; text/descriptor pointer and a destination), so the table walk below
	; must borrow and give them back. The target address is pushed under
	; the caller's own return address and reached with RET, which is the
	; only way to restore BOTH pairs and still transfer control.
	PUSH	HL
	PUSH	DE
	LD	L,A
	LD	H,0
	ADD	HL,HL
	LD	DE,JUMP_TABLE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	EX	DE,HL			; HL = target
	POP	DE			; caller's DE
	EX	(SP),HL			; HL = caller's HL, target now on the stack
	RET				; enter the target; its own RET returns to COLD.RUN
.UNKNOWN
	RET

JUMP_TABLE
	DW	@IPV4.BUILD		; 0  CFN_IPV4_BUILD
	DW	@IPV4.PARSE		; 1  CFN_IPV4_PARSE
	DW	@TCP.BUILD		; 2  CFN_TCP_BUILD
	DW	@TCP.PARSE		; 3  CFN_TCP_PARSE
	DW	@UDP.BUILD		; 4  CFN_UDP_BUILD
	DW	@UDP.PARSE		; 5  CFN_UDP_PARSE
	DW	@ICMP.BUILD_ECHO	; 6  CFN_ICMP_BUILD_ECHO
	DW	@ICMP.PARSE_ECHO_REPLY	; 7  CFN_ICMP_PARSE_REPLY
	DW	ARP_BUILD_REQUEST	; 8  CFN_ARP_BUILD_REQUEST
	DW	ARP_BUILD_REPLY		; 9  CFN_ARP_BUILD_REPLY
	DW	ARP_PARSE		; 10 CFN_ARP_PARSE
	DW	@DNSX.BUILD_QUERY	; 11 CFN_DNS_BUILD_QUERY
	DW	@DNSX.PARSE_DNS_REPLY	; 12 CFN_DNS_PARSE_REPLY
	DW	PARSE_IPV4		; 13 CFN_PARSE_IPV4
	DW	PARSE_MAC		; 14 CFN_PARSE_MAC
	DW	PARSE_HW		; 15 CFN_PARSE_HW
	DW	PARSE_U16		; 16 CFN_PARSE_U16
	DW	@ETHERNET.UDP_IPV4_CHECKSUM	; 17 CFN_ETH_UDP_CHECKSUM
	DW	FORMAT_IPV4		; 18 CFN_FORMAT_IPV4
	DW	@DNSX.BUILD_FRAME	; 19 CFN_DNS_BUILD_FRAME
	DW	@DNSX.PARSE_REPLY_FRAME	; 20 CFN_DNS_PARSE_FRAME
	DW	@DNSX.VALIDATE_NAME	; 21 CFN_DNS_VALIDATE_NAME
	DW	PING_BUILD_ECHO		; 22 CFN_PING_BUILD_ECHO
	DW	PING_PARSE_REPLY	; 23 CFN_PING_PARSE_REPLY
	DW	PARSE_PORT		; 24 CFN_PARSE_PORT
	DW	UDP_CTX_PTR		; 25 CFN_UDP_CTX_PTR
	DW	SELECT_UDP_CONTEXT	; 26 CFN_SELECT_UDP_CONTEXT
	DW	@DNSX.NONZERO_IP	; 27 CFN_DNS_NONZERO_IP
	DW	@DNSX.COPY_RESULT	; 28 CFN_DNS_COPY_RESULT
	DW	MAP_RECV_FAIL		; 29 CFN_MAP_RECV_FAIL
	DW	MAP_CONNECT_FAIL	; 30 CFN_MAP_CONNECT_FAIL
	DW	TCP_FAST_RECEIVE	; 31 CFN_TCP_FAST_RECEIVE
	DW	EL3_BASE_ENCODE		; 32 CFN_EL3_BASE_ENCODE
	DW	EL3_VALIDATE		; 33 CFN_EL3_VALIDATE
	DW	TCP_IP_BUILD		; 34 CFN_TCP_IP_BUILD
	DW	MAP_SEND_FAIL		; 35 CFN_MAP_SEND_FAIL
	DW	MAP_DNS_FAIL		; 36 CFN_MAP_DNS_FAIL
	ASSERT	($ - JUMP_TABLE) / 2 == CFN_COUNT

	INCLUDE "ethernet.asm"
	INCLUDE "ipv4.asm"
	INCLUDE "tcp.asm"
	INCLUDE "udp.asm"
	INCLUDE "icmp.asm"

; ======================================================
; DLL fast receive predicate and commit path. IX always addresses COLD_CTX;
; IY is the selected hot TCP context. Every hot address is reached through a
; pointer in COLD_CTX, including the only two callbacks. The callbacks perform
; the FIFO copy/discard while WIN0 remains mapped to this blob, so a caller
; destination in WIN0 is deliberately rejected to the old pending slow path.
; ======================================================
TCP_FAST_RECEIVE
	; Per-frame result consumed by the hot drain loop. A rejected checksum is
	; handled/discarded but must not look like directly delivered data.
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_FAST_DIRECT-S11_STATE_BASE
	ADD	HL,BC
	LD	(HL),0
	LD	A,IYH
	OR	IYL
	JP	Z,.SLOW
	LD	A,(IY+CTX_STATE)
	CP	TCP_STATE_ESTABLISHED
	JR	Z,.STATE_OK
	CP	TCP_STATE_FIN_WAIT
	JP	NZ,.SLOW
.STATE_OK
	; A live RECV whose destination is hidden by the cold mapping must use the
	; ordinary full-frame/pending path.
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_RX_DEST-S11_STATE_BASE
	ADD	HL,BC
	INC	HL
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = S11_RX_FREE
	LD	A,D
	OR	E
	JR	Z,.CALLER_VISIBLE
	DEC	HL
	DEC	HL			; HL = S11_RX_DEST+1
	LD	A,(HL)
	AND	0xC0
	JP	Z,.SLOW
.CALLER_VISIBLE
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	PUSH	HL
	LD	DE,12
	ADD	HL,DE
	LD	A,(HL)
	CP	0x08
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(HL)
	CP	0x45
	JP	NZ,.POP_SLOW
	LD	DE,6
	ADD	HL,DE			; IPv4 flags/fragment offset
	LD	A,(HL)
	AND	0xBF
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.POP_SLOW
	INC	HL
	INC	HL
	LD	A,(HL)
	CP	TCP_PROTOCOL
	JP	NZ,.POP_SLOW
	POP	HL			; RX buffer
	PUSH	HL
	LD	DE,30
	ADD	HL,DE
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	CALL	FAST_CMP4
	JP	NZ,.POP_SLOW
	POP	HL
	PUSH	HL
	LD	DE,14
	ADD	HL,DE
	LD	BC,IPV4_HEADER_LENGTH
	CALL	@ETHERNET.VERIFY_CHECKSUM
	JP	C,.POP_SLOW
	POP	HL
	PUSH	HL
	LD	DE,16
	ADD	HL,DE
	LD	A,(HL)
	LD	D,A
	INC	HL
	LD	E,(HL)			; DE = IP total length
	EX	DE,HL
	LD	DE,IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	OR	A
	SBC	HL,DE
	JP	C,.POP_SLOW
	LD	A,H
	OR	L
	JP	Z,.POP_SLOW
	LD	DE,TCP_MSS+1
	OR	A
	SBC	HL,DE
	JP	NC,.POP_SLOW
	ADD	HL,DE
	LD	(.LENGTH),HL
	LD	DE,14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	ADD	HL,DE
	EX	DE,HL			; DE = required frame bytes
	LD	L,(IX+CCTX_DNS_RX_LEN)
	LD	H,(IX+CCTX_DNS_RX_LEN+1)
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE
	JP	C,.POP_SLOW
	POP	HL
	PUSH	HL
	LD	DE,46
	ADD	HL,DE
	LD	A,(HL)
	CP	0x50
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(HL)
	AND	~(TCP_FLAG_ACK|TCP_FLAG_PSH)
	JP	NZ,.POP_SLOW
	LD	A,(HL)
	AND	TCP_FLAG_ACK
	JP	Z,.POP_SLOW
	; Four-tuple and in-order sequence must match IY exactly.
	POP	HL
	PUSH	HL
	LD	DE,26
	ADD	HL,DE
	PUSH	IY
	POP	DE
	INC	DE
	CALL	FAST_CMP4
	JP	NZ,.POP_SLOW
	POP	HL
	PUSH	HL
	LD	DE,34
	ADD	HL,DE
	LD	A,(IY+CTX_REMOTE_PORT+1)
	CP	(HL)
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(IY+CTX_REMOTE_PORT)
	CP	(HL)
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(IY+CTX_LOCAL_PORT+1)
	CP	(HL)
	JP	NZ,.POP_SLOW
	INC	HL
	LD	A,(IY+CTX_LOCAL_PORT)
	CP	(HL)
	JP	NZ,.POP_SLOW
	INC	HL			; sequence starts at RX+38
	PUSH	IY
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	FAST_CMP4
	JP	NZ,.POP_SLOW
	POP	HL			; discard saved RX base

	; Prefer the active caller buffer. Otherwise append to this context's
	; one-MSS pending region; neither case commits until the checksum passes.
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_RX_DEST-S11_STATE_BASE
	ADD	HL,BC
	LD	E,L
	LD	D,H			; DE = state base
	INC	HL
	INC	HL
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = RX_FREE
	LD	A,B
	OR	C
	JR	Z,.TRY_PENDING
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = RX_DELIVERED
	PUSH	HL
	EX	DE,HL
	INC	HL
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = RX_FREE
	POP	DE
	OR	A
	SBC	HL,DE
	LD	DE,(.LENGTH)
	OR	A
	SBC	HL,DE
	JR	C,.TRY_PENDING
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_RX_DEST-S11_STATE_BASE
	ADD	HL,BC
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = RX_DEST
	INC	HL
	INC	HL
	INC	HL
	LD	A,(HL)
	INC	HL
	LD	H,(HL)
	LD	L,A			; HL = RX_DELIVERED
	ADD	HL,DE
	LD	(.DEST),HL
	LD	A,1
	LD	(.DIRECT),A
	JR	.DEST_READY
.TRY_PENDING
	LD	L,(IY+CTX_PENDING_OFF)
	LD	H,(IY+CTX_PENDING_OFF+1)
	LD	E,(IY+CTX_PENDING_LEN)
	LD	D,(IY+CTX_PENDING_LEN+1)
	ADD	HL,DE
	EX	DE,HL			; DE = occupied prefix
	LD	HL,TCP_MSS
	OR	A
	SBC	HL,DE
	LD	DE,(.LENGTH)
	OR	A
	SBC	HL,DE
	JP	C,.SLOW
	LD	L,(IX+CCTX_TCP_PENDING0)
	LD	H,(IX+CCTX_TCP_PENDING0+1)
	LD	E,(IY+CTX_PENDING_OFF)
	LD	D,(IY+CTX_PENDING_OFF+1)
	ADD	HL,DE
	LD	E,(IY+CTX_PENDING_LEN)
	LD	D,(IY+CTX_PENDING_LEN+1)
	ADD	HL,DE
	LD	E,(IX+CCTX_TCP_CONTEXT0)
	LD	D,(IX+CCTX_TCP_CONTEXT0+1)
	PUSH	IY
	POP	BC
	LD	A,B
	CP	D
	JR	NZ,.PENDING1
	LD	A,C
	CP	E
	JR	Z,.PENDING_READY
.PENDING1
	LD	DE,TCP_MSS
	ADD	HL,DE
.PENDING_READY
	LD	(.DEST),HL
	XOR	A
	LD	(.DIRECT),A
.DEST_READY
	IFNDEF TCPX_UNCHECKED_DATA_RX
	; Seed the TCP checksum from the fixed pseudo/header bytes; RX_PAYLOAD_SUM
	; continues the same RFC-1071 carry while copying the payload from FIFO.
	LD	DE,0
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	BC,26
	ADD	HL,BC
	LD	BC,8
	CALL	@ETHERNET.ACCUMULATE
	LD	HL,TCP_PROTOCOL
	CALL	@TCP.ADD_ACCUMULATOR
	LD	HL,(.LENGTH)
	LD	BC,TCP_HEADER_LENGTH
	ADD	HL,BC
	CALL	@TCP.ADD_ACCUMULATOR
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	BC,34
	ADD	HL,BC
	LD	BC,TCP_HEADER_LENGTH
	CALL	@ETHERNET.ACCUMULATE
	EX	DE,HL
	LD	E,(IX+CCTX_EL3_RXS_SUM)
	LD	D,(IX+CCTX_EL3_RXS_SUM+1)
	LD	A,L
	LD	(DE),A
	INC	DE
	LD	A,H
	LD	(DE),A
	LD	L,(IX+CCTX_CB_RX_PAYLOAD_SUM)
	LD	H,(IX+CCTX_CB_RX_PAYLOAD_SUM+1)
	ELSE
	LD	L,(IX+CCTX_CB_RX_PAYLOAD)
	LD	H,(IX+CCTX_CB_RX_PAYLOAD+1)
	ENDIF
	LD	DE,.AFTER_PAYLOAD
	PUSH	DE
	PUSH	HL
	LD	DE,(.DEST)
	LD	BC,(.LENGTH)
	RET				; indirect CALL hot callback
.AFTER_PAYLOAD
	RET	C			; driver status is already in A/CF
	IFNDEF TCPX_UNCHECKED_DATA_RX
	LD	L,(IX+CCTX_EL3_RXS_SUM)
	LD	H,(IX+CCTX_EL3_RXS_SUM+1)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	A,D
	AND	E
	INC	A
	JR	Z,.COMMIT
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_FAST_BADSUM-S11_STATE_BASE
	ADD	HL,BC
	INC	(HL)
	JR	NZ,.BADSUM_DONE
	INC	HL
	INC	(HL)
.BADSUM_DONE
	XOR	A
	SCF				; handled/discarded, but uncommitted
	RET
	ENDIF
.COMMIT
	LD	DE,(.LENGTH)
	LD	A,(.DIRECT)
	OR	A
	JR	Z,.COMMIT_PENDING
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_RX_DEST-S11_STATE_BASE
	ADD	HL,BC
	LD	BC,4
	ADD	HL,BC
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	(HL),D
	DEC	HL
	LD	(HL),E
	JR	.ADVANCE
.COMMIT_PENDING
	LD	L,(IY+CTX_PENDING_LEN)
	LD	H,(IY+CTX_PENDING_LEN+1)
	ADD	HL,DE
	LD	(IY+CTX_PENDING_LEN),L
	LD	(IY+CTX_PENDING_LEN+1),H
	LD	A,(IY+CTX_EVENT)
	OR	EVENT_DATA
	LD	(IY+CTX_EVENT),A
.ADVANCE
	LD	DE,(.LENGTH)		; direct commit used DE for cumulative delivered
	PUSH	IY
	POP	HL
	LD	BC,CTX_RCV_NXT
	ADD	HL,BC
	CALL	FAST_ADD16_TO32

	; Piggybacked ACK/window processing mirrors HANDLE_SEGMENT's .NO_ACK path.
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	BC,42
	ADD	HL,BC
	PUSH	IY
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	FAST_CMP4
	JR	NZ,.ACK_OWED
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	BC,42
	ADD	HL,BC
	PUSH	IY
	POP	DE
	LD	BC,CTX_SND_UNA
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	B,4
.COPY_ACK
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	DE
	DJNZ	.COPY_ACK
	LD	L,(IX+CCTX_RX_BUF)
	LD	H,(IX+CCTX_RX_BUF+1)
	LD	BC,48
	ADD	HL,BC
	LD	A,(HL)
	LD	(IY+CTX_REMOTE_WINDOW+1),A
	INC	HL
	LD	A,(HL)
	LD	(IY+CTX_REMOTE_WINDOW),A
	LD	A,(IY+CTX_EVENT)
	OR	EVENT_ACK
	LD	(IY+CTX_EVENT),A
.ACK_OWED
	LD	A,(.DIRECT)
	OR	A
	JR	Z,.DIRECT_FLAG_DONE
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_FAST_DIRECT-S11_STATE_BASE
	ADD	HL,BC
	LD	(HL),1
.DIRECT_FLAG_DONE
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_MATCH_CONTEXT-S11_STATE_BASE
	ADD	HL,BC
	PUSH	IY
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,(.DIRECT)
	OR	A
	JR	NZ,.HANDLED
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	BC,S11_ACK_NOW-S11_STATE_BASE
	ADD	HL,BC
	LD	(HL),1
.HANDLED
	XOR	A
	SCF
	RET
.POP_SLOW
	POP	HL
.SLOW
	OR	A
	RET
.LENGTH	DW 0
.DEST		DW 0
.DIRECT	DB 0

FAST_CMP4
	LD	B,4
.LOOP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.LOOP
	RET

; In: HL points at a four-byte network-order value, DE is a 16-bit addend.
FAST_ADD16_TO32
	INC	HL
	INC	HL
	INC	HL
	LD	A,(HL)
	ADD	A,E
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	ADC	A,D
	LD	(HL),A
	RET	NC
	DEC	HL
	INC	(HL)
	RET	NZ
	DEC	HL
	INC	(HL)
	RET

; Pure cold copies of the infrequent DLL EEPROM helpers. HL is the EEPROM
; byte buffer and DE the six-byte station-MAC destination for VALIDATE.
EL3_BASE_ENCODE
	PUSH	HL
	LD	A,L
	AND	0x0F
	JR	NZ,.BAD_POP
	OR	A
	LD	DE,EL3_BASE_MIN
	SBC	HL,DE
	JR	C,.BAD_POP
	LD	DE,EL3_BASE_MAX-EL3_BASE_MIN
	EX	DE,HL
	OR	A
	SBC	HL,DE
	JR	C,.BAD_POP
	EX	DE,HL
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	LD	B,A
	LD	A,H
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0x10
	OR	B
	POP	HL
	OR	A
	RET
.BAD_POP
	POP	HL
	LD	A,EL3_ERR_BASE
	SCF
	RET

EL3_VALIDATE
	LD	(.EEPROM),HL
	LD	(.MAC),DE
	LD	DE,6
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	HL,EL3_PRODUCT_3C509B_TPO
	OR	A
	SBC	HL,DE
	JP	NZ,.NOT_FOUND
	LD	HL,(.EEPROM)
	LD	DE,14
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	HL,EL3_MFG_3COM
	OR	A
	SBC	HL,DE
	JP	NZ,.NOT_FOUND
	LD	HL,(.EEPROM)
	INC	HL
	BIT	0,(HL)
	JP	NZ,.NOT_FOUND
	DEC	HL
	LD	B,6
	LD	C,0
	LD	D,0xFF
.MAC_SCAN
	LD	A,(HL)
	LD	E,A
	OR	C
	LD	C,A
	LD	A,E
	AND	D
	LD	D,A
	INC	HL
	DJNZ	.MAC_SCAN
	LD	A,C
	OR	A
	JP	Z,.NOT_FOUND
	LD	A,D
	CP	0xFF
	JP	Z,.NOT_FOUND
	; Primary checksum lanes.
	LD	HL,(.EEPROM)
	LD	B,15
	LD	C,0
	LD	D,0
	LD	E,0
.PRIMARY
	LD	A,C
	CP	0x08
	JR	Z,.PRIMARY_CONFIG
	CP	0x09
	JR	Z,.PRIMARY_CONFIG
	CP	0x0D
	JR	Z,.PRIMARY_CONFIG
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	LD	A,(HL)
	XOR	D
	LD	D,A
	JR	.PRIMARY_NEXT
.PRIMARY_CONFIG
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	LD	A,(HL)
	XOR	E
	LD	E,A
.PRIMARY_NEXT
	INC	HL
	INC	C
	DJNZ	.PRIMARY
	LD	HL,(.EEPROM)
	LD	BC,0x1E
	ADD	HL,BC
	LD	A,(HL)
	CP	E
	JR	NZ,.CHECKSUM_BAD
	INC	HL
	LD	A,(HL)
	CP	D
	JR	NZ,.CHECKSUM_BAD
	; Secondary checksum lanes: 10..12 and 18..3F vital, 13..16 config.
	LD	HL,(.EEPROM)
	LD	BC,0x20
	ADD	HL,BC
	LD	D,0
	LD	E,0
	LD	B,3
	CALL	.XOR_D
	LD	HL,(.EEPROM)
	LD	BC,0x30
	ADD	HL,BC
	LD	B,40
	CALL	.XOR_D
	LD	HL,(.EEPROM)
	LD	BC,0x26
	ADD	HL,BC
	LD	B,4
	CALL	.XOR_E
	LD	HL,(.EEPROM)
	LD	BC,0x2E
	ADD	HL,BC
	LD	A,(HL)
	CP	E
	JR	NZ,.CHECKSUM_BAD
	INC	HL
	LD	A,(HL)
	CP	D
	JR	NZ,.CHECKSUM_BAD
	; Copy the factory MAC in network byte order.
	LD	HL,(.EEPROM)
	INC	HL
	LD	DE,(.MAC)
	LD	B,3
.COPY_MAC
	LD	A,(HL)
	LD	(DE),A
	DEC	HL
	INC	DE
	LD	A,(HL)
	LD	(DE),A
	INC	HL
	INC	HL
	INC	HL
	INC	DE
	DJNZ	.COPY_MAC
	XOR	A
	RET
.XOR_D
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	LD	A,(HL)
	XOR	D
	LD	D,A
	INC	HL
	DJNZ	.XOR_D
	RET
.XOR_E
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	LD	A,(HL)
	XOR	E
	LD	E,A
	INC	HL
	DJNZ	.XOR_E
	RET
.NOT_FOUND
	LD	A,EL3_ERR_NOT_FOUND
	SCF
	RET
.CHECKSUM_BAD
	LD	A,EL3_ERR_CHECKSUM
	SCF
	RET
.EEPROM	DW 0
.MAC		DW 0

TCP_IP_BUILD
	LD	A,D
	LD	(.FLAGS),A
	LD	(.PAYLOAD),BC
	; TCP descriptor, entirely cold; only its pointers target hot buffers/state.
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	LD	DE,14+IPV4_HEADER_LENGTH
	ADD	HL,DE
	LD	(.TCP_DESC+TCPB_BUFFER),HL
	LD	HL,1514-14-IPV4_HEADER_LENGTH
	LD	(.TCP_DESC+TCPB_CAPACITY),HL
	LD	L,(IX+CCTX_LOCAL_IP)
	LD	H,(IX+CCTX_LOCAL_IP+1)
	LD	(.TCP_DESC+TCPB_SOURCE_IP),HL
	PUSH	IY
	POP	HL
	INC	HL
	LD	(.TCP_DESC+TCPB_DESTINATION_IP),HL
	LD	L,(IY+CTX_LOCAL_PORT)
	LD	H,(IY+CTX_LOCAL_PORT+1)
	LD	(.TCP_DESC+TCPB_SOURCE_PORT),HL
	LD	L,(IY+CTX_REMOTE_PORT)
	LD	H,(IY+CTX_REMOTE_PORT+1)
	LD	(.TCP_DESC+TCPB_DESTINATION_PORT),HL
	PUSH	IY
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	PUSH	HL
	LD	E,(IX+CCTX_TCP_STATE_BASE)
	LD	D,(IX+CCTX_TCP_STATE_BASE+1)
	LD	HL,S11_SEQUENCE_OVERRIDE-S11_STATE_BASE
	ADD	HL,DE
	EX	DE,HL
	LD	A,(DE)
	OR	A
	JR	NZ,.USE_TARGET
	LD	A,(.FLAGS)
	AND	TCP_FLAG_SYN|TCP_FLAG_FIN
	JR	NZ,.USE_UNA
	LD	DE,(.PAYLOAD)
	LD	A,D
	OR	E
	JR	Z,.SEQUENCE_READY
.USE_UNA
	POP	HL
	LD	DE,CTX_SND_UNA-CTX_SND_NXT
	ADD	HL,DE
	JR	.SEQUENCE_SELECTED
.USE_TARGET
	POP	HL
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	DE,S11_TARGET_ACK-S11_STATE_BASE
	ADD	HL,DE
	JR	.SEQUENCE_SELECTED
.SEQUENCE_READY
	POP	HL
.SEQUENCE_SELECTED
	LD	(.TCP_DESC+TCPB_SEQUENCE),HL
	PUSH	IY
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	LD	(.TCP_DESC+TCPB_ACKNOWLEDGEMENT),HL
	LD	HL,(.PAYLOAD)
	LD	(.TCP_DESC+TCPB_PAYLOAD_LENGTH),HL
	LD	A,(.FLAGS)
	LD	(.TCP_DESC+TCPB_FLAGS),A

	; Durable pending space is always part of the promise. During the selected
	; channel's RECV, add the still-unfilled caller buffer, then advertise only
	; whole MSS units and clamp the result to five segments.
	LD	HL,TCP_MSS
	LD	E,(IY+CTX_PENDING_OFF)
	LD	D,(IY+CTX_PENDING_OFF+1)
	OR	A
	SBC	HL,DE
	LD	E,(IY+CTX_PENDING_LEN)
	LD	D,(IY+CTX_PENDING_LEN+1)
	SBC	HL,DE
	PUSH	HL
	LD	E,(IX+CCTX_TCP_STATE_BASE)
	LD	D,(IX+CCTX_TCP_STATE_BASE+1)
	LD	HL,S11_SELECTED_CONTEXT-S11_STATE_BASE
	ADD	HL,DE
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	PUSH	IY
	POP	DE
	LD	A,B
	CP	D
	JR	NZ,.DURABLE_ONLY
	LD	A,C
	CP	E
	JR	NZ,.DURABLE_ONLY
	LD	L,(IX+CCTX_TCP_STATE_BASE)
	LD	H,(IX+CCTX_TCP_STATE_BASE+1)
	LD	DE,S11_RX_DEST-S11_STATE_BASE
	ADD	HL,DE
	INC	HL
	LD	A,(HL)			; RX_DEST high byte
	AND	0xC0
	JR	Z,.DURABLE_ONLY		; WIN0 is hidden during cold receive
	INC	HL
	LD	C,(HL)
	INC	HL
	LD	B,(HL)			; BC = RX_FREE
	LD	A,B
	OR	C
	JR	Z,.DURABLE_ONLY
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = RX_DELIVERED
	LD	H,B
	LD	L,C
	OR	A
	SBC	HL,DE
	POP	DE			; durable space
	ADD	HL,DE
	JR	.WINDOW_TOTAL
.DURABLE_ONLY
	POP	HL
.WINDOW_TOTAL
	LD	DE,TCP_RECV_MAX_WINDOW
	OR	A
	SBC	HL,DE
	JR	NC,.WINDOW_MAX
	ADD	HL,DE
	LD	B,0
.WINDOW_DIVIDE
	LD	DE,TCP_MSS
	OR	A
	SBC	HL,DE
	JR	C,.WINDOW_QUOTIENT
	INC	B
	JR	.WINDOW_DIVIDE
.WINDOW_MAX
	LD	B,TCP_RECV_MAX_SEGMENTS
.WINDOW_QUOTIENT
	LD	A,B
	OR	A
	JR	Z,.WINDOW_SHUT
	RES	0,(IY+CTX_WINDOW_CLOSED)
	LD	A,B
	ADD	A,A
	ADD	A,A
	ADD	A,A
	LD	L,A			; 8*q
	ADD	A,A
	ADD	A,L			; 24*q
	LD	L,A
	LD	A,B
	ADD	A,A
	LD	H,A			; 512*q + 24*q
	JR	.WINDOW_READY
.WINDOW_SHUT
	SET	0,(IY+CTX_WINDOW_CLOSED)
	LD	HL,0
.WINDOW_READY
	LD	(.TCP_DESC+TCPB_WINDOW),HL
	LD	HL,0
	LD	A,(.FLAGS)
	AND	TCP_FLAG_SYN
	JR	Z,.MSS_READY
	LD	HL,TCP_MSS
.MSS_READY
	LD	(.TCP_DESC+TCPB_MSS),HL
	LD	HL,.TCP_DESC
	CALL	@TCP.BUILD
	JP	C,.RETURN
	LD	(.IP_DESC+IP4B_DATA_LENGTH),BC
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	LD	DE,14
	ADD	HL,DE
	LD	(.IP_DESC+IP4B_BUFFER),HL
	LD	HL,1514-14
	LD	(.IP_DESC+IP4B_CAPACITY),HL
	LD	L,(IX+CCTX_LOCAL_IP)
	LD	H,(IX+CCTX_LOCAL_IP+1)
	LD	(.IP_DESC+IP4B_SOURCE),HL
	PUSH	IY
	POP	HL
	INC	HL
	LD	(.IP_DESC+IP4B_DESTINATION),HL
	LD	E,(IX+CCTX_TCP_STATE_BASE)
	LD	D,(IX+CCTX_TCP_STATE_BASE+1)
	LD	HL,S11_IP_ID-S11_STATE_BASE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	(.IP_DESC+IP4B_IDENTIFIER),DE
	DEC	HL
	INC	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,64
	LD	(.IP_DESC+IP4B_TTL),A
	LD	A,TCP_PROTOCOL
	LD	(.IP_DESC+IP4B_PROTOCOL),A
	LD	HL,.IP_DESC
	CALL	@IPV4.BUILD
	JR	C,.RETURN
	LD	(.IP_LENGTH),BC
	PUSH	IY
	POP	HL
	LD	DE,CTX_REMOTE_MAC
	ADD	HL,DE
	LD	E,(IX+CCTX_TX_BUF)
	LD	D,(IX+CCTX_TX_BUF+1)
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	LD	HL,(.IP_LENGTH)
	LD	DE,14
	ADD	HL,DE
	LD	B,H
	LD	C,L
	LD	L,(IX+CCTX_TX_BUF)
	LD	H,(IX+CCTX_TX_BUF+1)
	XOR	A
	; SEND_SEGMENT promises to preserve its selected context. Return IY in IX
	; here so the hot path need not stack it across this combined cold call.
.RETURN
	PUSH	IY
	POP	IX
	RET
.FLAGS	DB 0
.PAYLOAD	DW 0
.IP_LENGTH	DW 0
.TCP_DESC	DS TCPB_DESC_LENGTH,0
.IP_DESC	DS IP4B_LENGTH,0

; ======================================================
; ARP cold rewrites. Byte-for-byte the same frame layout as arp.asm's
; (IFNDEF UNET_DLL) BUILD_REQUEST/BUILD_REPLY/PARSE; every direct
; NET_*/NETDRV_STATION_MAC reference there becomes a dereference of the
; matching COLD_CTX pointer field here.
; ======================================================
ARP_FRAME_LENGTH	EQU 60
ARP_OP_REQUEST		EQU 1
ARP_OP_REPLY		EQU 2

; ARP_BUILD_REQUEST
; In: IX=&COLD_CTX, DE=60-byte output, HL=target IPv4.
; Out: BC=60, A=0/CF=0.
ARP_BUILD_REQUEST
	LD	(.TARGET_IP),HL
	LD	A,0xFF
	LD	B,6
.RDST
	LD	(DE),A
	INC	DE
	DJNZ	.RDST
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	LD	A,0x06
	LD	(DE),A
	INC	DE
	LD	HL,FIXED_REQUEST
	LD	BC,8
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_LOCAL_IP)
	LD	H,(IX+CCTX_LOCAL_IP+1)
	LD	BC,4
	LDIR
	XOR	A
	LD	B,6
.RZERO
	LD	(DE),A
	INC	DE
	DJNZ	.RZERO
	LD	HL,(.TARGET_IP)
	LD	BC,4
	LDIR
	XOR	A
	LD	B,18
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	LD	BC,ARP_FRAME_LENGTH
	XOR	A
	RET
.TARGET_IP	DW 0

; ARP_BUILD_REPLY
; In: IX=&COLD_CTX, DE=output, HL=validated 60+ byte request. Out: BC=60.
ARP_BUILD_REPLY
	LD	(.INPUT_PTR),HL
	PUSH	HL
	LD	BC,22
	ADD	HL,BC			; requester SHA
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	LD	A,0x06
	LD	(DE),A
	INC	DE
	LD	HL,FIXED_REPLY
	LD	BC,8
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_LOCAL_IP)
	LD	H,(IX+CCTX_LOCAL_IP+1)
	LD	BC,4
	LDIR
	POP	HL
	LD	BC,22
	ADD	HL,BC
	LD	BC,6
	LDIR
	LD	HL,(.INPUT_PTR)
	LD	BC,28
	ADD	HL,BC			; requester SPA
	LD	BC,4
	LDIR
	XOR	A
	LD	B,18
.PAD
	LD	(DE),A
	INC	DE
	DJNZ	.PAD
	LD	BC,ARP_FRAME_LENGTH
	XOR	A
	RET
.INPUT_PTR	DW 0

; ARP_PARSE
; In: IX=&COLD_CTX, HL=frame, BC=received length. Out: A=1 matching reply
; for (CCTX_TARGET_IP), A=2 request for (CCTX_LOCAL_IP), CF=0; CF=1
; otherwise. Matching reply MAC is copied to (CCTX_RESULT_MAC).
ARP_PARSE
	LD	(.INPUT_PTR),HL
	LD	A,B
	OR	A
	JR	NZ,.LENGTH_OK
	LD	A,C
	CP	42
	JP	C,.NO
.LENGTH_OK
	LD	DE,12
	ADD	HL,DE
	LD	DE,FIXED_ETH_ARP
	LD	B,8
.FIXED
	LD	A,(DE)
	CP	(HL)
	JP	NZ,.NO
	INC	DE
	INC	HL
	DJNZ	.FIXED
	; Ethernet source and ARP sender hardware address must identify one peer.
	LD	HL,(.INPUT_PTR)
	LD	DE,6
	ADD	HL,DE
	LD	DE,(.INPUT_PTR)
	PUSH	HL
	EX	DE,HL
	LD	BC,22
	ADD	HL,BC
	EX	DE,HL
	POP	HL
	CALL	.CMP6
	JP	NZ,.NO
	; Opcode is a complete network-order word, not only its low byte.
	LD	HL,(.INPUT_PTR)
	LD	DE,20
	ADD	HL,DE
	LD	A,(HL)
	OR	A
	JP	NZ,.NO
	INC	HL
	LD	A,(HL)
	CP	ARP_OP_REPLY
	JR	Z,.REPLY
	CP	ARP_OP_REQUEST
	JR	NZ,.NO
	CALL	.DEST_FOR_US
	JR	NZ,.NO
	LD	HL,(.INPUT_PTR)
	LD	DE,38
	ADD	HL,DE			; TPA
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	CALL	.CMP4
	JR	NZ,.NO
	LD	A,2
	OR	A
	JR	.RETURN
.REPLY
	LD	HL,(.INPUT_PTR)
	LD	E,(IX+CCTX_STATION_MAC)
	LD	D,(IX+CCTX_STATION_MAC+1)
	CALL	.CMP6
	JR	NZ,.NO
	LD	HL,(.INPUT_PTR)
	LD	DE,32
	ADD	HL,DE
	LD	E,(IX+CCTX_STATION_MAC)
	LD	D,(IX+CCTX_STATION_MAC+1)
	CALL	.CMP6
	JR	NZ,.NO
	LD	HL,(.INPUT_PTR)
	LD	DE,38
	ADD	HL,DE
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	CALL	.CMP4
	JR	NZ,.NO
	LD	HL,(.INPUT_PTR)
	LD	DE,28
	ADD	HL,DE			; SPA
	LD	E,(IX+CCTX_NEXT_HOP_IP)
	LD	D,(IX+CCTX_NEXT_HOP_IP+1)
	CALL	.CMP4
	JR	NZ,.NO
	LD	HL,(.INPUT_PTR)
	LD	DE,22
	ADD	HL,DE
	LD	E,(IX+CCTX_RESULT_MAC)
	LD	D,(IX+CCTX_RESULT_MAC+1)
	LD	BC,6
	LDIR
	LD	A,1
	OR	A
	JR	.RETURN
.NO
	LD	A,NETDRV_ERR_PARAMETER
	SCF
.RETURN
	RET
.INPUT_PTR	DW 0

; Valid ARP requests may be Ethernet broadcast or unicast to this station.
; Out: Z if the frame at (.INPUT_PTR) is addressed to us.
.DEST_FOR_US
	LD	HL,(ARP_PARSE.INPUT_PTR)
	LD	E,(IX+CCTX_STATION_MAC)
	LD	D,(IX+CCTX_STATION_MAC+1)
	CALL	.CMP6
	RET	Z
	LD	HL,(ARP_PARSE.INPUT_PTR)
	LD	B,6
.BCAST
	LD	A,(HL)
	CP	0xFF
	RET	NZ
	INC	HL
	DJNZ	.BCAST
	RET

.CMP4
	LD	B,4
.CMP4_LOOP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.CMP4_LOOP
	RET

.CMP6
	LD	B,6
.CMP6_LOOP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.CMP6_LOOP
	RET

FIXED_REQUEST	DB 0,1,0x08,0,6,4,0,ARP_OP_REQUEST
FIXED_REPLY	DB 0,1,0x08,0,6,4,0,ARP_OP_REPLY
; EtherType + ARP htype/ptype/hlen/plen. Opcode is checked separately.
FIXED_ETH_ARP	DB 0x08,0x06,0,1,0x08,0,6,4

; ======================================================
; Text-argument parsers moved from stage9_app.asm (hot bytes were tight;
; see the plan's byte budget). Each is byte-for-byte the same accept/reject
; behaviour as the original hot version it replaces -- only fixed-address
; scratch became register/stack scratch, since cold code cannot reference
; hot BSS addresses directly. stage9_app.asm's own copies are now IFDEF
; UNET_DLL trampolines (LD A,CFN_x / JP @COLD.RUN) into these.
; ======================================================

; PARSE_MAC: HL=hex string (colon-separated), DE=6-byte output.
; Out: CF=1 on error. Trashes A, B, C, HL.
PARSE_MAC
	LD	B,6
.MAC_BYTE
	LD	A,(HL)
	CALL	.HEX_NIBBLE
	RET	C
	RLCA
	RLCA
	RLCA
	RLCA
	LD	C,A
	INC	HL
	LD	A,(HL)
	CALL	.HEX_NIBBLE
	RET	C
	OR	C
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	JR	Z,.MAC_END
	LD	A,(HL)
	CP	':'
	JR	NZ,.MAC_BAD
	INC	HL
	JR	.MAC_BYTE
.MAC_END
	LD	A,(HL)
	OR	A
	RET	Z
.MAC_BAD
	SCF
	RET
.HEX_NIBBLE
	CP	'0'
	JR	C,.NIB_BAD
	CP	'9'+1
	JR	C,.NIB_DEC
	CALL	.UPPER
	CP	'A'
	JR	C,.NIB_BAD
	CP	'F'+1
	JR	NC,.NIB_BAD
	SUB	'A'-10
	OR	A
	RET
.NIB_DEC
	SUB	'0'
	OR	A
	RET
.NIB_BAD
	SCF
	RET
.UPPER
	CP	'a'
	RET	C
	CP	'z'+1
	RET	NC
	SUB	'a'-'A'
	RET

; PARSE_U16: HL="#" + up to 4 hex digits. Out: HL=value (the closing
; EX DE,HL), DE=one past the last digit consumed, CF=1 on error (missing
; '#', bad digit, more than 4 digits, or zero digits). Trashes A, B, C.
PARSE_U16
	LD	A,(HL)
	CP	'#'
	JR	NZ,.HASH_BAD
	INC	HL
	LD	DE,0
	LD	B,0
.HEX
	LD	A,(HL)
	OR	A
	JR	Z,.HEX_DONE
	CALL	PARSE_MAC.HEX_NIBBLE
	JR	C,.HASH_BAD
	LD	C,A
	LD	A,D
	AND	0xF0
	JR	NZ,.HASH_BAD
	SLA	E
	RL	D
	SLA	E
	RL	D
	SLA	E
	RL	D
	SLA	E
	RL	D
	LD	A,E
	OR	C
	LD	E,A
	INC	HL
	INC	B
	LD	A,B
	CP	5
	JR	C,.HEX
.HASH_BAD
	SCF
	RET
.HEX_DONE
	LD	A,B
	OR	A
	JR	Z,.HASH_BAD
	EX	DE,HL
	OR	A
	RET

; PARSE_IPV4: HL=ASCIIZ dotted-decimal text, DE=4-byte output. Out: CF=1
; on error (missing field, overflow, non-digit, or trailing bytes).
; Trashes A, BC, HL, IX, IY. DE is only ever written to, never read, so it
; survives untouched for the caller to reuse.
;
; The hot original this replaces used S9_FLAGS/S9_PRIMARY_ERROR/
; S9_RX_LENGTH as scratch for, respectively, the current digit's value,
; the field's digit count, and an intermediate in the x10 multiply. Cold
; code can't reference those fixed hot addresses, so each becomes a
; register instead: the digit count lives in IXH (LD IX,0 resets it once
; per field; PUSH AF/POP IX and PUSH IX/POP AF move a byte in and out of
; it using only documented opcodes -- PUSH AF stores A at the pushed
; pair's high byte, which POP IX then loads into IXH, and vice versa) and
; the digit value lives in IYH the same way. Every push/pop pair below is
; immediately balanced before any branch, so the stack is exactly as the
; caller left it at every exit.
PARSE_IPV4
	LD	B,4
.IP_FIELD
	LD	C,0
	LD	IX,0			; IXH = digit count for this field
.IP_DIGIT
	LD	A,(HL)
	CP	'0'
	JR	C,.IP_END_FIELD
	CP	'9'+1
	JR	NC,.IP_END_FIELD
	SUB	'0'
	PUSH	AF
	POP	IY			; IYH = digit value
	LD	A,C
	CP	26
	JR	NC,.IP_BAD
	ADD	A,A			; A = C*2
	LD	C,A
	ADD	A,A
	ADD	A,A			; A = C*8 (from the same C*2 doubled twice)
	ADD	A,C			; A = C*8 + C*2 = C*10 (C<26 guarantees no overflow)
	LD	C,A
	PUSH	IY
	POP	AF			; A = digit value (IYH)
	ADD	A,C			; A = C*10 + digit
	JR	C,.IP_BAD
	LD	C,A
	PUSH	IX
	POP	AF			; A = digit count (IXH)
	INC	A
	PUSH	AF
	POP	IX			; IXH = updated digit count
	CP	4
	JR	NC,.IP_BAD
	INC	HL
	JR	.IP_DIGIT
.IP_END_FIELD
	PUSH	IX
	POP	AF			; A = digit count (IXH)
	OR	A
	JR	Z,.IP_BAD
	LD	A,C
	LD	(DE),A
	INC	DE
	DEC	B
	JR	Z,.IP_TERM
	LD	A,(HL)
	CP	'.'
	JR	NZ,.IP_BAD
	INC	HL
	JR	.IP_FIELD
.IP_TERM
	LD	A,(HL)
	OR	A
	RET	Z
.IP_BAD
	SCF
	RET

; FORMAT_IPV4: HL=4-byte binary IP, DE=destination (>=16 bytes ASCIIZ
; "a.b.c.d"). Out: DE=at the terminating NUL. Trashes A, BC, HL, IY.
; F_RESOLVE's own use: DNSX.RESOLVE_OR_LITERAL accepts both a literal dotted
; quad and a hostname, and either way leaves only the binary result at
; NET_TARGET_IP -- the caller's output buffer needs text, so the shim
; reformats it here instead of keeping RESOLVE's old "copy the validated
; source text back" shortcut (which only worked for the literal-IP case).
FORMAT_IPV4
	LD	C,4
.OCTET
	LD	A,(HL)
	INC	HL
	PUSH	BC			; FORMAT_U8 divides by B/C, so the octet counter
	CALL	FORMAT_U8	; cannot live in either half of BC across it
	POP	BC
	DEC	C
	JR	Z,.DONE
	LD	A,'.'
	LD	(DE),A
	INC	DE
	JR	.OCTET
.DONE
	XOR	A
	LD	(DE),A
	RET

; FORMAT_U8: A=value (0..255), DE=dest. Out: DE=past the last emitted digit
; (1-3 ASCII digits, no leading zeros; "0" emits a single '0').
; Trashes A, BC, IY. IYH substitutes for a fixed hot scratch byte (this is cold
; code -- see PARSE_IPV4's own header comment on the same PUSH AF/POP IX(Y)
; trick for moving a byte into/out of a half-register with documented
; opcodes only).
FORMAT_U8
	PUSH	AF
	XOR	A
	PUSH	AF
	POP	IY			; IYH = 0 ("a digit has been emitted" flag)
	POP	AF			; A = value, restored
	LD	C,100
	CALL	.DIGIT
	LD	C,10
	CALL	.DIGIT
	ADD	A,'0'			; units digit always emitted
	LD	(DE),A
	INC	DE
	RET
; Emit A/C as one digit (suppressing a leading zero); A = A mod C.
.DIGIT
	LD	B,'0'
.LOOP
	SUB	C
	JR	C,.UNDO
	INC	B
	JR	.LOOP
.UNDO
	ADD	A,C			; A = remainder
	PUSH	AF
	LD	A,B
	CP	'0'
	JR	NZ,.EMIT		; non-zero digit: always emit
	PUSH	IY
	POP	AF			; A = IYH (emitted-so-far flag)
	OR	A
	JR	Z,.SKIP			; leading zero, nothing emitted yet: suppress
.EMIT
	LD	A,B
	LD	(DE),A
	INC	DE
	LD	A,1
	PUSH	AF
	POP	IY			; IYH = 1
.SKIP
	POP	AF
	RET

; PARSE_HW: HL=text ("0/#XXXX" or "1/#XXXX", already length-bounded by the
; hot caller's CHECK_STRARG). Out: CF=1 on error; CF=0: A=slot(0/1),
; HL=validated base address. The hot stub (stage9_app.asm) stores both
; into NETDRV_CONFIG -- a fixed hot address this cold function cannot
; reference -- and sets NETDRV_CFG_MODE itself.
; The slot digit rides on the stack, not in B: PARSE_U16 uses B as its own
; digit counter and BASE_ENCODE builds its result there, so B does not
; survive either call. PARSE_U16 already returns the value in HL (its own
; closing EX DE,HL), and BASE_ENCODE preserves HL, so the base address is
; simply left where the hot stub expects to read it.
PARSE_HW
	LD	A,(HL)
	CP	'0'
	JR	Z,.slot0
	CP	'1'
	JR	NZ,.bad
	LD	A,1
	JR	.slot
.slot0
	XOR	A
.slot
	PUSH	AF
	INC	HL
	LD	A,(HL)
	CP	'/'
	JR	NZ,.bad_pop
	INC	HL
	CALL	PARSE_U16
	JR	C,.bad_pop
	CALL	BASE_ENCODE
	JR	C,.bad_pop
	POP	AF			; A = slot; OR A also clears CF
	OR	A
	RET
.bad_pop
	POP	AF
.bad
	SCF
	RET

; BASE_ENCODE: byte-for-byte el3_algorithms.asm's own copy (In: HL=base
; I/O address. Out: CF=0/A=encoded byte, HL preserved; CF=1/A=EL3_ERR_BASE
; on an unaligned or out-of-range address) -- PARSE_HW only needs its
; validation, not the encoded byte, but duplicating the real algorithm
; keeps the accept/reject boundary identical to the hot original's.
BASE_ENCODE
	PUSH	HL
	LD	A,L
	AND	0x0F
	JR	NZ,.BAD_POP
	OR	A
	LD	DE,EL3_BASE_MIN
	SBC	HL,DE
	JR	C,.BAD_POP
	LD	DE,EL3_BASE_MAX-EL3_BASE_MIN
	EX	DE,HL
	OR	A
	SBC	HL,DE
	JR	C,.BAD_POP
	EX	DE,HL
	LD	A,L
	RRCA
	RRCA
	RRCA
	RRCA
	AND	0x0F
	LD	B,A
	LD	A,H
	RLCA
	RLCA
	RLCA
	RLCA
	AND	0x10
	OR	B
	POP	HL
	OR	A
	RET
.BAD_POP
	POP	HL
	LD	A,EL3_ERR_BASE
	SCF
	RET

; ======================================================
; DNS cold codec, moved from stage12_dns.asm's hot MODULE DNSX (see that
; file's own IFDEF UNET_DLL branches). Byte-for-byte the same wire format
; and accept/reject behaviour as the hot original; every reference to a
; fixed hot address (DNS_TRANSACTION_ID, DNS_RESULT_IP, S9_RX_PAYLOAD,
; S9_DRAIN_LEFT) becomes a dereference through the matching COLD_CTX
; pointer field instead (coldctx.inc's CCTX_DNS_*), since cold code cannot
; reference those addresses directly. IX=&COLD_CTX throughout; nothing
; below touches IX itself, so it survives every internal CALL unchanged.
; GENERATE_ID/VALIDATE_NAME/NONZERO_IP/COPY_RESULT stay hot (GENERATE_ID
; needs DSS_SYSTIME, forbidden here; the others have no fixed-address need).
; ======================================================
	MODULE DNSX

; BUILD_QUERY: HL=name, DE=destination. Out: BC=query length.
BUILD_QUERY
	PUSH	DE
	PUSH	HL
	LD	L,(IX+CCTX_DNS_XID)
	LD	H,(IX+CCTX_DNS_XID+1)
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	POP	HL
	LD	A,B
	LD	(DE),A
	INC	DE
	LD	A,C
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A
	LD	B,6
.BQ_ZERO
	LD	(DE),A
	INC	DE
	DJNZ	.BQ_ZERO
.BQ_LABEL
	PUSH	DE
	INC	DE
	LD	B,0
.BQ_CHAR
	LD	A,(HL)
	OR	A
	JR	Z,.BQ_END
	INC	HL
	CP	'.'
	JR	Z,.BQ_LABEL_END
	LD	(DE),A
	INC	DE
	INC	B
	JR	.BQ_CHAR
.BQ_LABEL_END
	POP	IY
	LD	(IY+0),B
	LD	A,(HL)
	OR	A
	JR	NZ,.BQ_LABEL
	JR	.BQ_ROOT		; trailing dot already ended the final label
.BQ_END
	POP	IY
	LD	(IY+0),B
	XOR	A
.BQ_ROOT
	LD	(DE),A
	INC	DE
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	INC	DE
	LD	A,1
	LD	(DE),A
	POP	HL
	EX	DE,HL
	OR	A
	SBC	HL,DE
	INC	HL
	LD	B,H
	LD	C,L
	XOR	A
	RET

; PARSE_DNS_REPLY: HL=DNS payload, BC=length. Compressed owner names are
; skipped safely; the first A/IN answer is returned and CNAME/unknown RRs
; are bounded by RDLENGTH.
PARSE_DNS_REPLY
	LD	D,H
	LD	E,L			; DE = original payload start
	ADD	HL,BC			; HL = exclusive end; BC (length) untouched
	EX	DE,HL			; DE = end, HL = original start
	PUSH	HL			; save original start; HL free to clobber
	LD	L,(IX+CCTX_DNS_PAYLOAD_END)
	LD	H,(IX+CCTX_DNS_PAYLOAD_END+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D			; S9_RX_PAYLOAD = exclusive end
	POP	HL			; HL = original start; BC still = length
	LD	A,B
	OR	A
	JR	NZ,.PR_HAVE_HEADER
	LD	A,C
	CP	12
	JP	C,.PR_BAD
.PR_HAVE_HEADER
	PUSH	HL
	LD	L,(IX+CCTX_DNS_XID)
	LD	H,(IX+CCTX_DNS_XID+1)
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	POP	HL
	LD	A,B
	CP	(HL)
	JP	NZ,.PR_STALE
	INC	HL
	LD	A,C
	CP	(HL)
	JP	NZ,.PR_STALE
	INC	HL
	LD	A,(HL)
	AND	0xFA
	CP	0x80
	JP	NZ,.PR_BAD
	INC	HL
	LD	A,(HL)
	AND	0x0F
	JR	Z,.PR_COUNTS
	CP	3
	LD	A,NETDRV_ERR_DNS_NXDOMAIN
	JP	Z,.PR_ERROR
	JP	.PR_BAD
.PR_COUNTS
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.PR_BAD
	INC	HL
	LD	A,(HL)
	CP	1
	JP	NZ,.PR_BAD
	INC	HL
	LD	A,(HL)
	OR	A
	JP	NZ,.PR_BAD
	INC	HL
	LD	A,(HL)
	OR	A
	JP	Z,.PR_NO_ANSWER
	PUSH	HL
	LD	L,(IX+CCTX_DNS_DRAIN)
	LD	H,(IX+CCTX_DNS_DRAIN+1)
	LD	(HL),A
	POP	HL
	LD	DE,5
	ADD	HL,DE			; skip remaining counts to question name
	CALL	SKIP_DNS_NAME
	JR	C,.PR_BAD
	LD	DE,4
	CALL	ADVANCE_BOUNDED
	JR	C,.PR_BAD
.PR_ANSWER
	CALL	SKIP_DNS_NAME
	JR	C,.PR_BAD
	LD	DE,10
	CALL	ADVANCE_BOUNDED
	JR	C,.PR_BAD
	PUSH	HL
	LD	DE,-10
	ADD	HL,DE
	LD	B,0
	LD	A,(HL)
	OR	A
	JR	NZ,.PR_META
	INC	HL
	LD	A,(HL)
	CP	1
	JR	NZ,.PR_META
	INC	HL
	LD	A,(HL)
	OR	A
	JR	NZ,.PR_META
	INC	HL
	LD	A,(HL)
	CP	1
	JR	NZ,.PR_META
	LD	B,1
.PR_META
	POP	HL			; RDLENGTH is the word immediately before RDATA
	DEC	HL
	LD	E,(HL)
	DEC	HL
	LD	D,(HL)
	INC	HL
	INC	HL
	LD	A,D
	OR	A
	JR	NZ,.PR_SKIP
	LD	A,B
	CP	1
	JR	NZ,.PR_SKIP
	LD	A,E
	CP	4
	JR	NZ,.PR_SKIP
	LD	DE,4
	CALL	ADVANCE_BOUNDED
	JR	C,.PR_BAD
	LD	DE,-4
	ADD	HL,DE			; HL = RDATA (source)
	EX	DE,HL			; DE = source, HL free
	LD	L,(IX+CCTX_DNS_RESULT)
	LD	H,(IX+CCTX_DNS_RESULT+1)
	EX	DE,HL			; HL = source, DE = &DNS_RESULT_IP
	LD	BC,4
	LDIR
	XOR	A
	RET
.PR_SKIP
	CALL	ADVANCE_BOUNDED
	JR	C,.PR_BAD
	PUSH	HL
	LD	L,(IX+CCTX_DNS_DRAIN)
	LD	H,(IX+CCTX_DNS_DRAIN+1)
	LD	A,(HL)
	DEC	A
	LD	(HL),A
	POP	HL
	JR	NZ,.PR_ANSWER
.PR_NO_ANSWER
	LD	A,NETDRV_ERR_DNS_NO_ANSWER
	JR	.PR_ERROR
.PR_STALE
	LD	A,NETDRV_ERR_PARAMETER
	JR	.PR_ERROR
.PR_BAD
	LD	A,NETDRV_ERR_PROTOCOL
.PR_ERROR
	SCF
	RET

SKIP_DNS_NAME
	LD	B,64
.SN
	CALL	CHECK_ONE
	RET	C
	LD	A,(HL)
	OR	A
	JR	Z,.ROOT
	LD	C,A
	AND	0xC0
	CP	0xC0
	JR	Z,.POINTER
	LD	A,C
	CP	64
	JR	NC,.BAD_NAME
	LD	E,A
	LD	D,0
	INC	HL
	CALL	ADVANCE_BOUNDED
	RET	C
	DJNZ	.SN
.BAD_NAME
	SCF
	RET
.ROOT
	INC	HL
	OR	A
	RET
.POINTER
	INC	HL
	CALL	CHECK_ONE
	RET	C
	INC	HL
	OR	A
	RET

CHECK_ONE
	PUSH	HL
	LD	L,(IX+CCTX_DNS_PAYLOAD_END)
	LD	H,(IX+CCTX_DNS_PAYLOAD_END+1)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	POP	HL
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	CCF
	RET

ADVANCE_BOUNDED
	ADD	HL,DE
	JR	C,.AB_BAD
	PUSH	HL
	LD	L,(IX+CCTX_DNS_PAYLOAD_END)
	LD	H,(IX+CCTX_DNS_PAYLOAD_END+1)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	POP	HL
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JR	C,.AB_OK
	JR	Z,.AB_OK
.AB_BAD
	SCF
	RET
.AB_OK
	OR	A
	RET

; COPY_RESULT: copies the resolved DNS_RESULT_IP into NET_TARGET_IP.
COPY_RESULT
	LD	L,(IX+CCTX_DNS_RESULT)
	LD	H,(IX+CCTX_DNS_RESULT+1)
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	LD	BC,4
	LDIR
	RET

; NONZERO_IP: HL=4-byte IP. Out: Z if all four bytes are zero. Preserves HL.
NONZERO_IP
	PUSH	HL
	LD	B,4
	XOR	A
.NZ_LOOP
	OR	(HL)
	INC	HL
	DJNZ	.NZ_LOOP
	POP	HL
	RET

; ------------------------------------------------------
; DNS_PORT/DNS_LOCAL_PORT: byte-for-byte stage12_dns.asm's own values (that
; file's hot MODULE DNSX defines them too, but this is a separate assembly
; -- see this file's own header comment on why nothing here is INCLUDEd
; from the hot side). DNSX_TX_CAPACITY has no separate cold copy: cold code
; is always the DLL variant, so STAGE9_RX_CAPACITY is used directly.
DNS_PORT	EQU 53
DNS_LOCAL_PORT	EQU 0xD035

; DNS_BUFPTR: HL=small offset. Out: HL=DNSX_TX_BUFFER+offset (the RX-buffer
; alias -- see stage12_dns.asm's own header comment). Trashes DE.
; ------------------------------------------------------
DNS_BUFPTR
	LD	E,(IX+CCTX_RX_BUF)
	LD	D,(IX+CCTX_RX_BUF+1)
	ADD	HL,DE
	RET

; Shared read/write helpers for the S9_IPV4_BUILD_DESC/PARSE_DESC structs:
; fixed hot addresses reached only through their own CCTX pointer, since
; BUILD_FRAME/PARSE_REPLY_FRAME cannot reference them directly.
DNS_WRITE_BUILD_FIELD		; In: HL=field offset, DE=value (word)
	PUSH	DE
	LD	E,(IX+CCTX_DNS_IP_BUILD_DESC)
	LD	D,(IX+CCTX_DNS_IP_BUILD_DESC+1)
	ADD	HL,DE
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

DNS_WRITE_BUILD_BYTE		; In: HL=field offset, A=value
	PUSH	AF
	LD	E,(IX+CCTX_DNS_IP_BUILD_DESC)
	LD	D,(IX+CCTX_DNS_IP_BUILD_DESC+1)
	ADD	HL,DE
	POP	AF
	LD	(HL),A
	RET

DNS_WRITE_PARSE_FIELD		; In: HL=field offset, DE=value (word)
	PUSH	DE
	LD	E,(IX+CCTX_DNS_IP_PARSE_DESC)
	LD	D,(IX+CCTX_DNS_IP_PARSE_DESC+1)
	ADD	HL,DE
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D
	RET

DNS_WRITE_PARSE_BYTE		; In: HL=field offset, A=value
	PUSH	AF
	LD	E,(IX+CCTX_DNS_IP_PARSE_DESC)
	LD	D,(IX+CCTX_DNS_IP_PARSE_DESC+1)
	ADD	HL,DE
	POP	AF
	LD	(HL),A
	RET

DNS_READ_PARSE_FIELD		; In: HL=field offset. Out: DE=value (word)
	PUSH	HL
	LD	L,(IX+CCTX_DNS_IP_PARSE_DESC)
	LD	H,(IX+CCTX_DNS_IP_PARSE_DESC+1)
	POP	DE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	RET

; BUILD_FRAME: byte-for-byte the same wire format as stage12_dns.asm's own
; (IFNDEF UNET_DLL) hot original -- see that file's header comment on this
; trampoline. IX=&COLD_CTX throughout; no register argument (the name
; pointer, like every other fixed hot address this needs, comes through
; its own CCTX_DNS_* field). Out: CF=1 propagated from BUILD_QUERY or
; IPV4.BUILD; CF=0 on success (CCTX_DNS_FRAME_LEN holds the total length).
BUILD_FRAME
	LD	L,(IX+CCTX_DNS_NAME_PTR)
	LD	H,(IX+CCTX_DNS_NAME_PTR+1)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = DNS_NAME_POINTER's value (name text)
	EX	DE,HL			; HL = name text
	PUSH	HL
	LD	HL,42
	CALL	DNS_BUFPTR		; HL = DNSX_TX_BUFFER+42
	EX	DE,HL
	POP	HL			; HL = name text, DE = destination
	CALL	BUILD_QUERY		; -> BC = query length, CF on error
	RET	C
	; Minimal UDP header. A zero checksum is valid for IPv4.
	LD	HL,34
	CALL	DNS_BUFPTR
	LD	(HL),HIGH DNS_LOCAL_PORT
	INC	HL
	LD	(HL),LOW DNS_LOCAL_PORT
	INC	HL
	LD	(HL),0
	INC	HL
	LD	(HL),DNS_PORT
	PUSH	BC			; save query length
	LD	HL,38
	CALL	DNS_BUFPTR		; loads the buffer base into DE, so the UDP
					; length has to be built AFTER this call:
					; built before, the base address itself
					; landed in the length field and every
					; resolver dropped the query
	PUSH	HL
	LD	HL,8
	ADD	HL,BC			; BC still holds the query length
	EX	DE,HL			; DE = UDP length (query+8)
	POP	HL			; HL = DNSX_TX_BUFFER+38
	LD	(HL),D
	INC	HL
	LD	(HL),E
	INC	HL
	LD	(HL),0
	INC	HL
	LD	(HL),0
	POP	BC			; BC = query length
	LD	HL,8
	ADD	HL,BC			; HL = IPv4 payload length (UDP length)
	EX	DE,HL
	LD	HL,IP4B_DATA_LENGTH
	CALL	DNS_WRITE_BUILD_FIELD
	LD	HL,14
	CALL	DNS_BUFPTR
	EX	DE,HL			; DE = DNSX_TX_BUFFER+14
	LD	HL,IP4B_BUFFER
	CALL	DNS_WRITE_BUILD_FIELD
	LD	DE,STAGE9_RX_CAPACITY-14
	LD	HL,IP4B_CAPACITY
	CALL	DNS_WRITE_BUILD_FIELD
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	LD	HL,IP4B_SOURCE
	CALL	DNS_WRITE_BUILD_FIELD
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	LD	HL,IP4B_DESTINATION
	CALL	DNS_WRITE_BUILD_FIELD
	LD	L,(IX+CCTX_IP_ID)
	LD	H,(IX+CCTX_IP_ID+1)	; HL = &S9_IP_ID
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = S9_IP_ID value
	INC	DE
	LD	L,(IX+CCTX_IP_ID)
	LD	H,(IX+CCTX_IP_ID+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D			; S9_IP_ID = value+1
	LD	HL,IP4B_IDENTIFIER
	CALL	DNS_WRITE_BUILD_FIELD
	LD	HL,IP4B_TTL
	LD	A,64
	CALL	DNS_WRITE_BUILD_BYTE
	LD	HL,IP4B_PROTOCOL
	LD	A,17
	CALL	DNS_WRITE_BUILD_BYTE
	LD	L,(IX+CCTX_DNS_IP_BUILD_DESC)
	LD	H,(IX+CCTX_DNS_IP_BUILD_DESC+1)
	CALL	@IPV4.BUILD
	RET	C
	; IPV4.BUILD returns the complete IP length in BC.
	LD	HL,14
	ADD	HL,BC
	EX	DE,HL			; DE = total frame length
	LD	L,(IX+CCTX_DNS_FRAME_LEN)
	LD	H,(IX+CCTX_DNS_FRAME_LEN+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	L,(IX+CCTX_RESULT_MAC)
	LD	H,(IX+CCTX_RESULT_MAC+1)
	LD	E,(IX+CCTX_RX_BUF)
	LD	D,(IX+CCTX_RX_BUF+1)	; DE = DNSX_TX_BUFFER (offset 0)
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	XOR	A
	RET

; PARSE_REPLY_FRAME: byte-for-byte the same accept/reject behaviour as
; stage12_dns.asm's own (IFNDEF UNET_DLL) hot original. IX=&COLD_CTX.
PARSE_REPLY_FRAME
	LD	HL,14
	CALL	DNS_BUFPTR		; HL = DNSX_TX_BUFFER+14 (== STAGE9_RX_BUFFER+14)
	EX	DE,HL
	LD	HL,IP4P_BUFFER
	CALL	DNS_WRITE_PARSE_FIELD
	LD	L,(IX+CCTX_DNS_RX_LEN)
	LD	H,(IX+CCTX_DNS_RX_LEN+1)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = S11_FRAME_LENGTH value
	EX	DE,HL			; HL = frame length
	LD	DE,14
	OR	A
	SBC	HL,DE
	EX	DE,HL			; DE = frame length - 14
	LD	HL,IP4P_LENGTH
	CALL	DNS_WRITE_PARSE_FIELD
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	LD	HL,IP4P_EXPECT_SOURCE
	CALL	DNS_WRITE_PARSE_FIELD
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	LD	HL,IP4P_EXPECT_DESTINATION
	CALL	DNS_WRITE_PARSE_FIELD
	LD	HL,IP4P_EXPECT_PROTOCOL
	LD	A,17
	CALL	DNS_WRITE_PARSE_BYTE
	LD	L,(IX+CCTX_DNS_IP_PARSE_DESC)
	LD	H,(IX+CCTX_DNS_IP_PARSE_DESC+1)
	CALL	@IPV4.PARSE
	JR	C,.NOISE
	LD	HL,IP4P_DATA_LENGTH
	CALL	DNS_READ_PARSE_FIELD	; DE = data length
	PUSH	DE
	POP	BC			; BC = data length
	LD	A,B
	OR	A
	JR	NZ,.UDP_SIZE
	LD	A,C
	CP	8
	JR	C,.NOISE
.UDP_SIZE
	LD	HL,IP4P_DATA
	CALL	DNS_READ_PARSE_FIELD	; DE = data pointer
	PUSH	DE
	POP	HL			; HL = data pointer
	LD	A,(HL)
	OR	A
	JR	NZ,.NOISE
	INC	HL
	LD	A,(HL)
	CP	DNS_PORT
	JR	NZ,.NOISE
	INC	HL
	LD	A,(HL)
	CP	HIGH DNS_LOCAL_PORT
	JR	NZ,.NOISE
	INC	HL
	LD	A,(HL)
	CP	LOW DNS_LOCAL_PORT
	JR	NZ,.NOISE
	INC	HL
	LD	D,(HL)
	INC	HL
	LD	E,(HL)
	INC	HL
	LD	A,D
	CP	B
	JR	NZ,.NOISE
	LD	A,E
	CP	C
	JR	NZ,.NOISE		; UDP length must match the parsed IPv4 payload
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	JR	Z,.CHECKSUM_OK		; an omitted UDP checksum is valid for IPv4
	PUSH	BC,HL
	LD	HL,14
	CALL	DNS_BUFPTR
	CALL	@ETHERNET.UDP_IPV4_CHECKSUM
	LD	A,H
	OR	L
	POP	HL,BC
	JR	NZ,.NOISE
.CHECKSUM_OK
	LD	A,C
	SUB	8
	LD	C,A
	JR	NC,.PAYLOAD_SIZE
	DEC	B
.PAYLOAD_SIZE
	JP	PARSE_DNS_REPLY
.NOISE
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

; VALIDATE_NAME: byte-for-byte stage12_dns.asm's own (IFNDEF UNET_DLL) hot
; original -- pure register logic, no CCTX pointer needed. HL=name text.
VALIDATE_NAME
	LD	B,0
	LD	C,0
.VN
	LD	A,(HL)
	OR	A
	JR	Z,.VN_END
	CP	0x21
	JR	C,.VN_BAD
	CP	0x7F
	JR	NC,.VN_BAD
	INC	C
	JR	Z,.VN_BAD
	CP	'.'
	JR	Z,.VN_DOT
	INC	B
	LD	A,B
	CP	64
	JR	NC,.VN_BAD
	INC	HL
	JR	.VN
.VN_DOT
	LD	A,B
	OR	A
	JR	Z,.VN_BAD
	LD	B,0
	INC	C
	INC	HL
	JR	.VN
.VN_END
	LD	A,B
	OR	C			; a single trailing dot terminates a valid prior label
	JR	Z,.VN_BAD
	XOR	A
	RET
.VN_BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

	ENDMODULE

; ======================================================
; PING cold codec, moved from unet509b.asm's own hand-rolled F_PING (see
; that file's own header comment on this trampoline). Byte-for-byte the
; same wire format/accept-reject behaviour; every fixed hot address becomes
; a CCTX_* dereference, reusing DNSX's own buffer/descriptor helpers above
; (S9_IPV4_BUILD_DESC/S9_IPV4_PARSE_DESC are the same shared scratch structs
; DNS's own BUILD_FRAME/PARSE_REPLY_FRAME use -- non-concurrent, never both
; in flight at once). IX=&COLD_CTX throughout.
; ======================================================

; PING_BUILD_ECHO: builds a complete Ethernet+IPv4+ICMP echo-request frame
; into (CCTX_RX_BUF) (the idle RX buffer -- see F_PING's own hot comment).
; Out: CF=1 on error (from ICMP.BUILD_ECHO/IPV4.BUILD); CF=0: BC=total frame
; length, DE=ICMP identifier (the caller stores this in UNET_ARG_IX to
; recognize the matching reply later).
PING_BUILD_ECHO
	LD	L,(IX+CCTX_RESULT_MAC)
	LD	H,(IX+CCTX_RESULT_MAC+1)
	LD	E,(IX+CCTX_RX_BUF)
	LD	D,(IX+CCTX_RX_BUF+1)
	PUSH	DE			; save buffer base
	LD	BC,6
	LDIR
	LD	L,(IX+CCTX_STATION_MAC)
	LD	H,(IX+CCTX_STATION_MAC+1)
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	POP	HL			; HL = buffer base
	LD	DE,34
	ADD	HL,DE			; HL = buffer+34 (ICMPB_BUFFER value)
	EX	DE,HL			; DE = buffer+34
	LD	L,(IX+CCTX_PING_BUILD_DESC)
	LD	H,(IX+CCTX_PING_BUILD_DESC+1)	; HL = &PING_ICMP_BUILD_DESC
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPB_BUFFER
	INC	HL
	LD	DE,STAGE9_RX_CAPACITY-34
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPB_CAPACITY
	INC	HL
	LD	(HL),0
	INC	HL
	LD	(HL),0				; ICMPB_PAYLOAD_LENGTH = 0
	INC	HL
	LD	A,R
	LD	E,A
	LD	D,0xC5				; DE = identifier
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPB_IDENTIFIER
	INC	HL
	LD	(HL),1
	INC	HL
	LD	(HL),0				; ICMPB_SEQUENCE = 1
	INC	HL
	LD	(HL),8				; ICMPB_TYPE = 8 (echo request)
	PUSH	DE				; save identifier across BUILD_ECHO/IPV4.BUILD
	LD	L,(IX+CCTX_PING_BUILD_DESC)
	LD	H,(IX+CCTX_PING_BUILD_DESC+1)
	CALL	@ICMP.BUILD_ECHO
	JR	C,.build_fail
	LD	D,B
	LD	E,C				; DE = ICMP length, for IP4B_DATA_LENGTH
	LD	HL,IP4B_DATA_LENGTH
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	HL,14
	CALL	@DNSX.DNS_BUFPTR		; HL = buffer+14
	EX	DE,HL
	LD	HL,IP4B_BUFFER
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	DE,STAGE9_RX_CAPACITY-14
	LD	HL,IP4B_CAPACITY
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	LD	HL,IP4B_SOURCE
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	LD	HL,IP4B_DESTINATION
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	L,(IX+CCTX_IP_ID)
	LD	H,(IX+CCTX_IP_ID+1)		; HL = &S9_IP_ID
	LD	E,(HL)
	INC	HL
	LD	D,(HL)				; DE = S9_IP_ID value
	PUSH	DE				; save value for the descriptor write below
	INC	DE
	LD	L,(IX+CCTX_IP_ID)
	LD	H,(IX+CCTX_IP_ID+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D				; S9_IP_ID = value+1
	POP	DE				; DE = original value
	LD	HL,IP4B_IDENTIFIER
	CALL	@DNSX.DNS_WRITE_BUILD_FIELD
	LD	HL,IP4B_TTL
	LD	A,64
	CALL	@DNSX.DNS_WRITE_BUILD_BYTE
	LD	HL,IP4B_PROTOCOL
	LD	A,IPV4_PROTOCOL_ICMP
	CALL	@DNSX.DNS_WRITE_BUILD_BYTE
	LD	L,(IX+CCTX_DNS_IP_BUILD_DESC)
	LD	H,(IX+CCTX_DNS_IP_BUILD_DESC+1)
	CALL	@IPV4.BUILD
	JR	C,.build_fail
	LD	HL,14
	ADD	HL,BC
	LD	B,H
	LD	C,L				; BC = total frame length
	OR	A				; CF=0
	POP	DE				; DE = identifier
	RET
.build_fail
	POP	DE				; balance the identifier PUSH above
	RET

; PING_PARSE_REPLY: In: DE=expected ICMP identifier (the hot caller's own
; UNET_ARG_IX). Out: CF=1 on any rejection (noise, wrong type, identifier/
; sequence mismatch -- caller loops back to its own tick/retry); CF=0
; success. Reuses S9_IPV4_PARSE_DESC (via DNSX's own helpers) the same way
; PARSE_REPLY_FRAME does; non-concurrent with DNS's own use of it.
PING_PARSE_REPLY
	PUSH	DE			; save expected identifier
	LD	DE,0
	LD	HL,IP4P_EXPECT_SOURCE
	CALL	@DNSX.DNS_WRITE_PARSE_FIELD
	LD	HL,IP4P_EXPECT_PROTOCOL
	LD	A,IPV4_PROTOCOL_ICMP
	CALL	@DNSX.DNS_WRITE_PARSE_BYTE
	LD	HL,14
	CALL	@DNSX.DNS_BUFPTR		; HL = buffer+14
	EX	DE,HL
	LD	HL,IP4P_BUFFER
	CALL	@DNSX.DNS_WRITE_PARSE_FIELD
	LD	L,(IX+CCTX_DNS_FRAME_LEN)
	LD	H,(IX+CCTX_DNS_FRAME_LEN+1)	; &S9_RX_LENGTH (PING's own frame length)
	LD	E,(HL)
	INC	HL
	LD	D,(HL)				; DE = S9_RX_LENGTH value
	EX	DE,HL				; HL = frame length
	LD	DE,14
	OR	A
	SBC	HL,DE				; HL = frame length - 14
	EX	DE,HL				; DE = value
	LD	HL,IP4P_LENGTH
	CALL	@DNSX.DNS_WRITE_PARSE_FIELD
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	LD	HL,IP4P_EXPECT_DESTINATION
	CALL	@DNSX.DNS_WRITE_PARSE_FIELD
	LD	L,(IX+CCTX_DNS_IP_PARSE_DESC)
	LD	H,(IX+CCTX_DNS_IP_PARSE_DESC+1)
	CALL	@IPV4.PARSE
	JR	C,.parse_fail
	LD	HL,IP4P_DATA
	CALL	@DNSX.DNS_READ_PARSE_FIELD	; DE = ICMP payload pointer
	PUSH	DE
	POP	HL				; HL = ICMP payload pointer
	LD	A,(HL)
	OR	A
	JR	NZ,.parse_fail			; type 0 = echo reply
	POP	DE				; DE = expected identifier (from entry)
	LD	L,(IX+CCTX_PING_REPLY_DESC)
	LD	H,(IX+CCTX_PING_REPLY_DESC+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPR_IDENTIFIER
	INC	HL
	LD	(HL),1
	INC	HL
	LD	(HL),0				; ICMPR_SEQUENCE = 1
	INC	HL
	LD	(HL),0
	INC	HL
	LD	(HL),0				; ICMPR_PAYLOAD_LENGTH = 0
	INC	HL
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPR_EXPECT_SOURCE
	INC	HL
	LD	E,(IX+CCTX_LOCAL_IP)
	LD	D,(IX+CCTX_LOCAL_IP+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D				; ICMPR_EXPECT_DESTINATION
	LD	HL,IP4P_DATA_LENGTH
	CALL	@DNSX.DNS_READ_PARSE_FIELD	; DE = ICMP payload length
	PUSH	DE
	LD	HL,IP4P_DATA
	CALL	@DNSX.DNS_READ_PARSE_FIELD	; DE = ICMP payload pointer
	EX	DE,HL				; HL = ICMP payload pointer
	POP	BC				; BC = ICMP payload length
	LD	E,(IX+CCTX_PING_REPLY_DESC)
	LD	D,(IX+CCTX_PING_REPLY_DESC+1)
	CALL	@ICMP.PARSE_ECHO_REPLY
	RET
.parse_fail
	POP	DE				; balance the entry PUSH above
	SCF
	RET

; MAP_RECV_FAIL: In: E=raw TCPX.RECV failure code (TCP_ERR_TIMEOUT already
; handled by the hot caller before CAPTURE_DIAG/this ever run). Out: A=NERR_*.
MAP_RECV_FAIL
	LD	A,E
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.cancel
	CP	NETDRV_ERR_PARAMETER
	JR	Z,.param
	LD	A,NERR_CLOSED			; TCP_ERR_CLOSED/TCP_ERR_RESET and any
	RET					; other status: the channel is gone
.cancel
	LD	A,NERR_CANCEL
	RET
.param
	LD	A,NERR_PARAM
	RET

; MAP_CONNECT_FAIL: In: E=raw TCPX.OPEN failure code. Out: A=NERR_*.
MAP_CONNECT_FAIL
	LD	A,E
	CP	NETDRV_ERR_PARAMETER
	JR	Z,.param
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.cancel
	CP	TCP_ERR_TIMEOUT
	JR	Z,.connect
	CP	TCP_ERR_RESET
	JR	Z,.connect
	CP	NETDRV_ERR_PROTOCOL
	JR	Z,.connect
	LD	A,NERR_HW
	RET
.connect
	LD	A,NERR_CONNECT
	RET
.cancel
	LD	A,NERR_CANCEL
	RET
.param
	LD	A,NERR_PARAM
	RET

; MAP_SEND_FAIL/MAP_DNS_FAIL: E carries the hot-side raw status because A is
; the cold dispatcher function number. CAPTURE_DIAG remains hot and runs
; before MAP_SEND_FAIL is entered.
MAP_SEND_FAIL
	LD	A,E
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.cancel
	CP	TCP_ERR_RESET
	JR	Z,.closed
	CP	TCP_ERR_CLOSED
	JR	Z,.closed
	CP	TCP_ERR_TIMEOUT
	JR	Z,.send
	CP	TCP_ERR_SEQUENCE
	JR	Z,.send
	CP	TCP_ERR_WINDOW
	JR	Z,.send
	CP	NETDRV_ERR_PROTOCOL
	JR	Z,.send
	LD	A,NERR_HW
	RET
.closed
	LD	A,NERR_CLOSED
	RET
.send
	LD	A,NERR_SEND
	RET
.cancel
	LD	A,NERR_CANCEL
	RET

MAP_DNS_FAIL
	LD	A,E
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.cancel
	CP	EL3_ERR_RX_TIMEOUT
	JR	Z,.timeout
	LD	A,NERR_DNS
	RET
.timeout
	LD	A,NERR_TIMEOUT
	RET
.cancel
	LD	A,NERR_CANCEL
	RET

; ======================================================
; Pure register-logic helpers moved from unet509b.asm's own MODULE UNET
; (no fixed hot address at all, so no CCTX pointer is needed here).
; ======================================================

; PARSE_PORT: HL=ASCIIZ decimal string. Out: HL=value (1..65535), CF=1 on
; an empty string, a non-digit, overflow past 65535, or a literal zero
; (port 0 is not connectable). Trashes A, BC, DE.
PARSE_PORT
	LD	BC,0
	LD	A,(HL)
	OR	A
	JR	Z,.bad
.digit
	LD	A,(HL)
	OR	A
	JR	Z,.done
	CP	'0'
	JR	C,.bad
	CP	'9'+1
	JR	NC,.bad
	SUB	'0'
	PUSH	HL
	LD	H,B
	LD	L,C
	ADD	HL,HL			; x2
	JR	C,.pop_bad
	LD	D,H
	LD	E,L
	ADD	HL,HL			; x4
	JR	C,.pop_bad
	ADD	HL,HL			; x8
	JR	C,.pop_bad
	ADD	HL,DE			; x8+x2 = x10
	JR	C,.pop_bad
	LD	E,A
	LD	D,0
	ADD	HL,DE
	JR	C,.pop_bad
	LD	B,H
	LD	C,L
	POP	HL
	INC	HL
	JR	.digit
.pop_bad
	POP	HL
.bad
	SCF
	RET
.done
	LD	A,B
	OR	C
	JR	Z,.bad
	LD	H,B
	LD	L,C
	OR	A
	RET

; UDP_CTX_PTR: In: E=channel, IX=&COLD_CTX. Out: HL=&UNET_UDP_CTX[channel].
UDP_CTX_PTR
	LD	L,(IX+CCTX_UDP_CTX_BASE)
	LD	H,(IX+CCTX_UDP_CTX_BASE+1)
	LD	A,E
	OR	A
	RET	Z
	LD	DE,UNET_UDP_CTX_SIZE
	ADD	HL,DE
	RET

; SELECT_UDP_CONTEXT: In: E=channel (already open as UDP), IX=&COLD_CTX.
; Copies UNET_UDP_CTX[E] into the udp_transport.asm scalars SEND/WAIT read
; (see unet509b.asm's own header comment on this trampoline).
SELECT_UDP_CONTEXT
	CALL	UDP_CTX_PTR		; HL = &UNET_UDP_CTX[channel]
	LD	E,(IX+CCTX_TARGET_IP)
	LD	D,(IX+CCTX_TARGET_IP+1)
	PUSH	HL
	LD	BC,4
	LDIR
	POP	HL
	LD	DE,4
	ADD	HL,DE
	LD	E,(IX+CCTX_RESULT_MAC)
	LD	D,(IX+CCTX_RESULT_MAC+1)
	PUSH	HL
	LD	BC,6
	LDIR
	POP	HL
	LD	DE,6
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	INC	HL			; HL = &ctx local port; DE = ctx remote port value
	PUSH	HL
	PUSH	DE
	LD	L,(IX+CCTX_S9_LOCAL_PORT)
	LD	H,(IX+CCTX_S9_LOCAL_PORT+1)
	INC	HL
	INC	HL			; HL = &S9_REMOTE_PORT (local+2)
	POP	DE
	LD	(HL),E
	INC	HL
	LD	(HL),D			; S9_REMOTE_PORT; HL now points at local+3
	INC	HL			; HL = &S9_EXPECT_REMOTE_PORT (local+4) -- ONE
					; increment: the store above already advanced HL
	LD	(HL),E
	INC	HL
	LD	(HL),D			; S9_EXPECT_REMOTE_PORT (same value)
	POP	HL			; HL = &ctx local port
	LD	E,(HL)
	INC	HL
	LD	D,(HL)			; DE = ctx local port value
	LD	L,(IX+CCTX_S9_LOCAL_PORT)
	LD	H,(IX+CCTX_S9_LOCAL_PORT+1)
	LD	(HL),E
	INC	HL
	LD	(HL),D			; S9_LOCAL_PORT
	RET

	ASSERT $ <= 0x3F80		; reserve upper 128 bytes for COLD.RUN stack
