; ======================================================
; UNET509B.DLL - 3C509B network backend for the UNET universal network API.
; libman 1.3 / L1 relocatable library. Implements the frozen contract in
; src/include/unet.inc on top of this kit's own driver and stack (el3 /
; netdrv / arp / dns / tcp / udp / icmp).
;
; Build (see tools/build.sh's build_dll):
;   sprinter-mkdll build src/dll/unet509b.asm --format l1 --target 1.3 \
;     --assembler sjasmplus -I src/include -I src/lib \
;     --name "UNET509B v<version>" --version <maj.min> --no-compress \
;     -o build/UNET509B.DLL
;   then a cold blob (src/dll/unet509b_cold.asm, assembled --raw) is
;   appended as [LE16 length][bytes] and the DLL is re-verified.
;
; --- Layout notes (mirrors the sibling UNETRTL.DLL; read before editing) --
;
; * Exactly ONE `ORG` may appear in this file, and it must be the first
;   one: sprinter-mkdll rewrites only the first ORG line it finds, to
;   0x20 and 0x120 for the two relocation passes (the 32-byte L1 header
;   precedes the code image).
; * The two passes must produce byte-identical LENGTHS; never make a DS
;   or a conditional depend on anything pass-sensitive.
; * Sizes must be literals, never a difference of two addresses - in a
;   relocatable image both operands get relocated.
; * The first bytes of the code image are the 24-entry JP table.
;   Dispatch is image_base + 0x20 + 3*function.
;
; --- Why the BSS lives INSIDE the image ---------------------------
;
; The repo rule against zero-filled buffers in an EXE is deliberately
; reversed here: libman relocates this DLL into window 1 (0x4000) or
; window 2 (0x8000), either of which may be where a consumer keeps its
; own state, and libman may pack several DLLs into one 16 KB page. So
; every byte of state is `DS n,0` inside the image (memory.inc's
; IFDEF UNET_DLL branch points every shared-library address at it) -
; a useful side effect is that l_free + l_load is a guaranteed clean
; reset, since every load re-zeroes the whole image from the file.
;
; --- ISA window discipline ----------------------------------------
;
; @ISA.OPEN samples the caller's IFF2, then DIs and maps the card at
; 0xC000..0xFFFF; @ISA.CLOSE restores MMU3 and that sampled IFF2 (EI
; only if it was set). EVERY UNET function returns with the window
; CLOSED and the caller's IFF restored to what it was on entry.
; Functions that only read the environment or shim state (GETCAPS,
; STATUS, GETINFO, LASTERR, SETOPT) never open it at all.
;
; Window 3 is refused at load time: it is the ISA aperture, and the
; cold overlay's own loader (win0cold.asm) stages into it before ISA
; is ever opened - a DLL living there would page itself out on every
; card access.
; ======================================================

	DEFINE	UNET_DLL
	DEFINE	STAGE12_LAYOUT		; tcp_transport.asm: deep receive window
	DEFINE	STAGE13_LAYOUT		; tcp_transport.asm: keep MULTICHAN (see the
					; TCPX_SINGLE_CONTEXT guard's IFNDEF STAGE13_LAYOUT)
	DEFINE	TCPX_LISTEN		; tcp_transport.asm: inbound TCP (P4)
	DEFINE	TCPX_ASYNCSEND		; tcp_transport.asm: SEND suspend/resume (P5)
	DEFINE	TCPX_DIRECT_RX		; defer/coalesce ACKs outside frame dispatch
	DEFINE	EL3_SESSION_RX		; two-phase FIFO receive and direct delivery

	INCLUDE "dss.inc"
	INCLUDE "sprinter.inc"
	INCLUDE "unet.inc"
	INCLUDE "coldctx.inc"

; Capability mask: full parity with UNETRTL (user decision, see the plan).
; RXFLOW clear: the 3C509B buffers receive in its own on-card FIFO, so
; RXPAUSE/RXRESUME are genuine no-ops. TRANSPARENT/RAWETH: no backend entry
; point, would be a lie to advertise.
UNET509B_CAPS	EQU UNET_CAP_TCP | UNET_CAP_UDP | UNET_CAP_RESOLVE | UNET_CAP_PING | UNET_CAP_MULTICHAN | UNET_CAP_ASYNCSEND | UNET_CAP_LISTEN
	ASSERT UNET509B_CAPS == 0x023F

UNET_CHANNELS	EQU 2
MAX_HOST_LEN	EQU 128
MAX_PORT_LEN	EQU 15

; Stable LASTERR "st=" stage codes (see BUILD_LASTERR).
ST_NETINIT	EQU 1
ST_CONNECT	EQU 2
ST_SEND		EQU 3
ST_RECV		EQU 4
ST_CLOSE	EQU 5

	ORG	0x0000			; the ONLY ORG; mkdll rewrites it
DLL_IMAGE_ORIGIN	EQU $

; ======================================================
; libman export table. Entry N is at image_base + 0x20 + 3*N.
; ======================================================
	MODULE UNET

	JP	INIT			; 0  load hook
	JP	FINI			; 1  free hook
	JP	F_GETCAPS		; 2
	JP	F_NETINIT		; 3
	JP	F_NETDONE		; 4
	JP	F_CONNECT		; 5
	JP	F_SEND			; 6
	JP	F_RECV			; 7
	JP	F_CLOSE			; 8
	JP	F_STATUS		; 9
	JP	F_UDPOPEN		; 10
	JP	F_RESOLVE		; 11
	JP	F_PING			; 12
	JP	F_RXPAUSE		; 13
	JP	F_RXRESUME		; 14
	JP	F_GETINFO		; 15
	JP	F_LASTERR		; 16
	JP	F_SETOPT		; 17
	JP	F_LISTEN		; 18
	JP	F_UNLISTEN		; 19
	JP	RET_NOTSUP		; 20 reserved
	JP	RET_NOTSUP		; 21 reserved
	JP	RET_NOTSUP		; 22 reserved
	JP	RET_NOTSUP		; 23 reserved

	ENDMODULE

; ======================================================
; In-image BSS. Placed immediately after the jump table so every symbol
; derived from it is a BACKWARD reference by the time memory.inc and the
; libraries are assembled. Offsets are literals on purpose (relocation
; rule); sizes come from the plan's byte budget (see the architecture doc).
; The offset table itself is shared with unet509b_cold.asm (which has no
; BSS of its own but needs the same symbols to resolve its own, unused,
; `INCLUDE "memory.inc"` -> memory_dll.inc chain) -- see unet509b_bss.inc.
; ======================================================
	INCLUDE "unet509b_bss.inc"

DLL_BSS
	DS	DLL_BSS_SIZE, 0
	DB	0xA5			; canary, checked by check-stage14.pl / the DLL's own image

RUNTIME_BASE	EQU DLL_BSS + BSS_RT
S9_ENV_BUFFER	EQU DLL_BSS + BSS_RX	; 256 bytes, RX is idle whenever env is read

	INCLUDE "memory.inc"		; IFDEF UNET_DLL -> memory_dll.inc

; ======================================================
; Driver stack. Same modules any Stage 11 EXE links, in the same order
; (see e.g. tcptest.asm); UNET_DLL/STAGE12_LAYOUT/STAGE13_LAYOUT (defined
; above) steer each file's own IFDEF branches -- ARP's real BUILD_REQUEST/
; BUILD_REPLY/PARSE and the whole codec layer (ethernet/ipv4/tcp/udp/icmp)
; live in the cold blob instead (see unet509b_cold.asm); what hot code
; needs from them is a pair of tiny trampoline modules right below.
; ======================================================
	INCLUDE "isa.asm"
	INCLUDE "el3_algorithms.asm"
	INCLUDE "el3_io.asm"
	INCLUDE "el3_fifo.asm"
	INCLUDE "el3_regs.asm"
	INCLUDE "el3.asm"
	INCLUDE "netdrv.asm"
	INCLUDE "arp.asm"
	INCLUDE "nettime.asm"
	INCLUDE "tcp_transport.asm"
	INCLUDE "udp_transport.asm"
	INCLUDE "stage9_app.asm"	; LOAD_ACTIVE_CONFIG + its text parsers
	INCLUDE "dns_ntp.inc"		; DNS_PORT etc. (constants only)
	INCLUDE "stage12_dns.asm"	; RESOLVE_OR_LITERAL (P3b hostname resolution)
	INCLUDE "win0cold.asm"

; ------------------------------------------------------
; Hot IPV4/TCP trampolines. tcp_transport.asm calls @IPV4.VALIDATE_REGION
; on every OPEN/SEND/RECV to bound a caller's buffer -- cheap, pure
; register logic with no fixed-address dependency, so it gets a real hot
; copy (byte-for-byte ipv4.asm's own) rather than a COLD.RUN round trip on
; every call. @IPV4.BUILD/@IPV4.PARSE/@TCP.BUILD/@TCP.PARSE are only
; reached once per segment, so they trampoline into the matching CFN_*
; cold function instead: HL already holds the descriptor pointer exactly
; as the real codec expects it, and COLD.RUN never touches HL/IX/IY, so
; the tail JP hands it through untouched.
; ------------------------------------------------------
	MODULE IPV4

; In: HL=start, BC=nonzero length. End is exclusive and must be <= C000h.
VALIDATE_REGION
	PUSH	HL,BC
	LD	A,B
	OR	C
	JR	Z,.REGION_BAD
	ADD	HL,BC
	JR	C,.REGION_BAD
	LD	DE,0xC001
	OR	A
	SBC	HL,DE
	JR	NC,.REGION_BAD
	XOR	A
	POP	BC,HL
	RET
.REGION_BAD
	SCF
	POP	BC,HL
	RET

BUILD
	LD	A,CFN_IPV4_BUILD
	JP	@COLD.RUN

PARSE
	LD	A,CFN_IPV4_PARSE
	JP	@COLD.RUN

	ENDMODULE

	MODULE TCP

	IFNDEF UNET_DLL
BUILD
	LD	A,CFN_TCP_BUILD
	JP	@COLD.RUN
	ENDIF

PARSE
	LD	A,CFN_TCP_PARSE
	JP	@COLD.RUN

	ENDMODULE

	MODULE UDP

BUILD
	LD	A,CFN_UDP_BUILD
	JP	@COLD.RUN

PARSE
	LD	A,CFN_UDP_PARSE
	JP	@COLD.RUN

	ENDMODULE

	MODULE ICMP

BUILD_ECHO
	LD	A,CFN_ICMP_BUILD_ECHO
	JP	@COLD.RUN

PARSE_ECHO_REPLY
	LD	A,CFN_ICMP_PARSE_REPLY
	JP	@COLD.RUN

	ENDMODULE

; ethernet.asm itself is not linked hot (its only hot-side use is this one
; checksum, called from stage12_dns.asm's PARSE_REPLY_FRAME to validate an
; optional UDP checksum on a DNS reply); the real routine lives in the cold
; blob's own unmodified copy (unet509b_cold.asm INCLUDEs ethernet.asm).
	MODULE ETHERNET

UDP_IPV4_CHECKSUM
	LD	A,CFN_ETH_UDP_CHECKSUM
	JP	@COLD.RUN

	ENDMODULE

; ======================================================
; UNET function bodies
; ======================================================
	MODULE UNET

; ------------------------------------------------------
; Function 0 - INIT (libman load hook). libman propagates THIS
; function's carry as the load error, so it is the one place CF
; matters. Learn our own window by popping the return address of a
; local CALL, and refuse window 3 (the ISA aperture).
; ------------------------------------------------------
INIT
	CALL	.here
.here
	POP	HL
	LD	A,H
	AND	0xC0
	LD	(UNET_WIN_BASE),A
	CP	0xC0
	JR	Z,.refuse
	XOR	A
	LD	(UNET_INITED),A
	JP	UNARM_LISTENER		; LISTEN_CHANNEL=0xFF (a zero-filled image would
					; read as "channel 0 listens"); returns A=0, CF=0
.refuse
	LD	A,NERR_HW
	SCF
	RET

; ------------------------------------------------------
; Function 1 - FINI (libman free hook). Closes anything still open the way
; NETDONE does, then the same forced teardown NETINIT starts with: card
; released, the cold overlay's DSS page freed (l_free would otherwise leak
; it), INITED cleared. The close status has no one to go to: TEARDOWN_LINK
; returns A=0, CF=0.
; ------------------------------------------------------
FINI
	CALL	CLOSE_LINK
	JP	TEARDOWN_LINK

; ------------------------------------------------------
; Function 2 - GETCAPS. Callable before NETINIT.
; ------------------------------------------------------
F_GETCAPS
	LD	DE,UNET509B_CAPS
	LD	IX,UNET_ABI_VERSION
	XOR	A
	RET

; ------------------------------------------------------
; Function 3 - NETINIT. Bring the link layer up: cold overlay -> env ->
; card. A repeated call is safe (TEARDOWN_LINK first).
;
; The overlay MUST be loaded before LOAD_ACTIVE_CONFIG runs: in this build
; its NET_HW/NET_IDPORT/NET_IP/NET_MASK parsers are COLD.RUN trampolines
; (stage9_app.asm PARSE_HW/PARSE_HASH/PARSE_IPV4 under UNET_DLL), and
; COLD.RUN returns CF=1 without running anything until COLD.INIT has
; succeeded -- which the config loader can only report as "bad config",
; i.e. a fully configured machine would get NERR_NONET forever.
; ------------------------------------------------------
F_NETINIT
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	TEARDOWN_LINK
	LD	A,ST_NETINIT
	LD	(UNET_STAGE),A
	CALL	@COLD.INIT
	JR	NC,.cold_ok
	LD	(UNET_TCP_LAST),A
	JP	RET_HW
.cold_ok
	CALL	@S9APP.LOAD_ACTIVE_CONFIG
	JP	C,RET_NONET
	CALL	@S9APP.INIT_DRIVER
	JR	NC,.driver_up
	CALL	CAPTURE_DIAG
	JP	RET_HW
.driver_up
	CALL	FILL_COLD_CTX
	CALL	@TCPX.RESET
	LD	A,1
	LD	(UNET_INITED),A
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 4 - NETDONE. Close every open channel as CLOSE does, without
; re-arming a listener; leave the env/card up for a fresh CONNECT/UDPOPEN
; without another NETINIT. Idempotent. A = the status of the channel that
; did not close cleanly (CLOSE_LINK).
; ------------------------------------------------------
F_NETDONE
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CLOSE_LINK
	JP	RET_A

; ------------------------------------------------------
; Function 5 - CONNECT (TCP). A=channel, DE=host ASCIIZ, IX=port ASCIIZ.
; P2 accepts only a dotted-quad literal for the host; hostname resolution
; arrives with P3's DNS overlay (RESOLVE/UDPOPEN/PING share the same gate).
; ------------------------------------------------------
F_CONNECT
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	CALL	CH_STATE_PTR
	LD	A,(HL)
	OR	A
	JP	NZ,RET_STATE			; already open
	LD	A,ST_CONNECT
	LD	(UNET_STAGE),A
	LD	A,(UNET_INITED)
	OR	A
	JP	Z,RET_STATE
	LD	HL,(UNET_ARG_DE)
	CALL	CHECK_HOST_ARG
	JP	C,RET_PARAM
	CALL	RESOLVE_HOST
	JP	C,DNS_FAIL_TAIL
	LD	HL,(UNET_ARG_IX)
	CALL	CHECK_PORT_ARG
	JP	C,RET_PARAM
	LD	B,H
	LD	C,L
	LD	A,(UNET_ARG_A)
	LD	HL,UNET_CONNECT_IP
	CALL	@TCPX.OPEN
	JR	NC,.opened
	CALL	MAP_CONNECT_FAIL
	JP	RET_A
.opened
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),1
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 6 - SEND. A=channel, DE=buffer, IX=length -> A, DE=bytes sent
; (valid on the error paths too). Zero length is a successful no-op.
; ------------------------------------------------------
F_SEND
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	IFDEF	TCPX_ASYNCSEND
	LD	A,(UNET_APEND_ACTIVE)
	OR	A
	JP	NZ,.resume
	ENDIF
	LD	A,(UNET_ARG_A)
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	A,ST_SEND
	LD	(UNET_STAGE),A
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	A,(HL)
	OR	A
	JP	Z,RET_STATE
	CP	2
	JP	Z,F_SEND_UDP
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JR	Z,.send_go			; zero length: skip the buffer check
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
.send_go
	LD	A,(UNET_ARG_A)
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	@TCPX.SEND
	JR	.send_tail
	IFDEF	TCPX_ASYNCSEND
.resume
	; A SEND is suspended. Only the SAME channel, buffer and length may
	; continue it -- a different call would lose the pending byte-count
	; result, and a fresh SEND on the pend channel would duplicate stream
	; bytes already sent.
	; UNET_APEND_CHANNEL/DE/IX and UNET_ARG_A/DE/IX are each five
	; contiguous bytes in BSS_UNET (memory_dll.inc) in the same layout --
	; one loop covers the channel, buffer and length compares together.
	LD	HL,UNET_APEND_CHANNEL
	LD	DE,UNET_ARG_A
	LD	B,5
.resume_cmp
	LD	A,(DE)
	CP	(HL)
	JP	NZ,RET_STATE
	INC	HL
	INC	DE
	DJNZ	.resume_cmp
	XOR	A
	LD	(UNET_APEND_ACTIVE),A		; consumed; a fresh AGAIN re-arms it
	LD	A,(UNET_ARG_A)
	CALL	@TCPX.SEND_RESUME
	ENDIF
.send_tail
	; TCPX.SEND and TCPX.SEND_RESUME both return the acknowledged byte
	; count in DE and CLOBBER BC (tcp_transport.asm's own header) -- unlike
	; TCPX.RECV, which returns its count in BC. DE is already the value
	; unet.inc promises the caller, so it must be passed through untouched;
	; the failure paths below already do exactly that.
	JR	C,.fail
	XOR	A
	JP	RET_A
.fail
	IFDEF	TCPX_ASYNCSEND
	CP	TCP_ERR_AGAIN
	JR	Z,.again
	ENDIF
	PUSH	DE
	; A peer RST ends the channel here and now, as UNETRTL does: nothing is
	; left to read or to close, and the pending bytes go with the context.
	; An accepted LISTEN channel is re-armed. Every other failure leaves the
	; channel open for RECV and for the caller's CLOSE.
	PUSH	AF
	CP	TCP_ERR_RESET
	CALL	Z,CLEAR_AND_RELEASE
	POP	AF
	CALL	MAP_SEND_FAIL
	POP	DE
	JP	RET_A
	IFDEF	TCPX_ASYNCSEND
.again
	; Not an error: the link was silent for one UNET_OPT_SENDSLICE quantum
	; but the send is still legitimately in flight. Park the resume
	; contract (the caller must repeat this exact call) and report
	; NERR_AGAIN with DE = bytes confirmed so far.
	; UNET_ARG_A/DE/IX and UNET_APEND_CHANNEL/DE/IX are each five
	; contiguous bytes in BSS_UNET (memory_dll.inc) in the same layout,
	; so one LDIR parks the whole resume contract.
	LD	HL,UNET_ARG_A
	LD	DE,UNET_APEND_CHANNEL
	LD	BC,5
	LDIR
	LD	A,1
	LD	(UNET_APEND_ACTIVE),A
	LD	A,NERR_AGAIN
	JP	RET_A
	ENDIF

; F_SEND_UDP: one datagram per call, staged at UDPX_TX_BUFFER+42 (see
; udp_transport.asm's own header comment on that buffer choice).
F_SEND_UDP
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JR	Z,.udp_copy_done
	LD	BC,1473
	OR	A
	SBC	HL,BC
	JP	NC,RET_PARAM
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	HL,(UNET_ARG_DE)
	LD	DE,@UDPX.UDPX_TX_BUFFER+42
	LD	BC,(UNET_ARG_IX)
	LDIR
.udp_copy_done
	LD	A,(UNET_ARG_A)
	CALL	SELECT_UDP_CONTEXT
	LD	BC,(UNET_ARG_IX)
	CALL	@UDPX.SEND
	JR	C,.udp_fail
	LD	DE,(UNET_ARG_IX)
	XOR	A
	JP	RET_A
.udp_fail
	CALL	MAP_SEND_FAIL
	LD	DE,0
	JP	RET_A

; ------------------------------------------------------
; Function 7 - RECV. A=channel, DE=buffer, IX=max, IY=timeout_ms ->
; A, DE=received, IX=flags. A timeout is reported as success/DE=0, not
; an error (unet.inc); IX (RXF_*) is always 0 -- this backend never sets
; the optional per-channel hints, matching UNETRTL.
; ------------------------------------------------------
F_RECV
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	; unet.inc reads IY=0 as "poll, do not block" (NERR_OK/DE=0 when the
	; link is idle), but NETTIME.START -- the timebase under every wait
	; below, TCP, UDP and accept alike -- documents BC=1..65535 and
	; rejects 0 with NETDRV_ERR_PARAMETER, which MAP_RECV_FAIL turns into
	; NERR_PARAM. One quantum still polls the card exactly once before it
	; expires, so clamp here, where all three paths pick the value up.
	PUSH	IY
	POP	HL
	LD	A,H
	OR	L
	JR	NZ,.have_timeout
	INC	L			; HL was 0
.have_timeout
	LD	(UNET_ARG_IY),HL
	LD	A,ST_RECV
	LD	(UNET_STAGE),A
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	A,(HL)
	OR	A
	JP	Z,RET_STATE
	CP	2
	JP	Z,F_RECV_UDP
	CP	3
	JP	Z,F_RECV_LISTEN
F_RECV_TCP
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM			; max=0 has no room
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(UNET_ARG_A)
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	LD	DE,(UNET_ARG_IY)
	CALL	@TCPX.RECV
	JR	C,.fail
	LD	IX,0
	LD	D,B
	LD	E,C
	XOR	A
	JP	RET_A
.fail
	CP	TCP_ERR_TIMEOUT
	JR	Z,.idle
	CALL	MAP_RECV_FAIL
	CP	NERR_CLOSED
	JR	NZ,.empty
	; The final NERR_CLOSED consumes the orderly-close marker and frees the
	; channel, matching UNETRTL. Payload is returned by earlier successful
	; RECV calls, so no pending byte is discarded here. An accepted LISTEN
	; channel is re-armed by RELEASE_OR_REARM instead of becoming idle.
	CALL	CLEAR_AND_RELEASE
	LD	A,NERR_CLOSED
	JR	.empty
.idle
	XOR	A
.empty
	LD	DE,0
	LD	IX,0
	JP	RET_A

; F_RECV_LISTEN: progress the pending accept. On success the channel
; becomes an ordinary established one and this same call also tries the
; normal TCP RECV path below, so data piggybacked on the handshake's
; closing ACK isn't left for a second RECV call to notice.
F_RECV_LISTEN
	LD	A,(UNET_ARG_A)
	LD	BC,(UNET_ARG_IY)
	CALL	@TCPX.ACCEPT_POLL
	OR	A
	JR	Z,.listen_idle
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),1
	LD	A,1
	LD	(UNET_LISTEN_ACCEPTED),A
	JP	F_RECV_TCP
.listen_idle
	JR	F_RECV_TCP.idle

; F_RECV_UDP: one datagram per call; oversized datagrams are truncated
; (UNET_RXF_TRUNC), matching unet.inc's documented UNETESP behaviour.
F_RECV_UDP
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM
	LD	A,(UNET_ARG_A)
	CALL	SELECT_UDP_CONTEXT
	LD	BC,(UNET_ARG_IY)
	CALL	@UDPX.WAIT
	JR	NC,.udp_got
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.udp_cancel
	JR	F_RECV_TCP.idle
.udp_cancel
	LD	A,NERR_CANCEL
	JR	F_RECV_TCP.empty
.udp_got
	; HL=payload, BC=length; truncate to the caller's max (UNET_ARG_IX).
	PUSH	HL
	LD	HL,(UNET_ARG_IX)
	OR	A
	SBC	HL,BC
	JR	NC,.udp_fits
	LD	BC,(UNET_ARG_IX)
	LD	IX,UNET_RXF_TRUNC
	JR	.udp_copy
.udp_fits
	LD	IX,0
.udp_copy
	POP	HL
	LD	DE,(UNET_ARG_DE)
	LD	(UNET_ARG_IY),BC
	LDIR
	LD	DE,(UNET_ARG_IY)
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 8 - CLOSE. A=channel -> A (unet.inc: NERR_OK when the peer
; acknowledged or answered, NERR_TIMEOUT when it never did, NERR_CANCEL when
; the user ended the wait, NERR_HW when a FIN or RST never left the card).
; Idempotent. The channel is released whatever the status; closing the
; channel LISTEN's own accept produced re-arms LISTEN on the same port
; instead of going idle (unet.inc's documented CLOSE contract).
; ------------------------------------------------------
F_CLOSE
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	A,ST_CLOSE
	LD	(UNET_STAGE),A
	CALL	CLOSE_CHANNEL
	JP	RET_A

; CLOSE_CHANNEL: close UNET_ARG_A's channel, UNETRTL's per-state rules.
; A listening channel (3) is dropped with nothing on the wire and its
; listener unarmed; any other channel's TCPX context decides for itself
; (TCPX.CLOSE: an idle or UDP channel's context is already closed).
; Out: A=NERR_*, the channel released or re-armed. Trashes BC/DE/HL/IX.
CLOSE_CHANNEL
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	A,(HL)
	CP	3
	JR	Z,.listening
	LD	A,(UNET_ARG_A)
	CALL	@TCPX.CLOSE
	JR	NC,RELEASE_WITH_STATUS
	CALL	CAPTURE_DIAG		; LASTERR: st=05 tcp=<raw>
	LD	E,A
	LD	A,CFN_MAP_CLOSE_FAIL
	CALL	@COLD.RUN
	JR	RELEASE_WITH_STATUS
.listening
	CALL	UNARM_LISTENER
; CLEAR_AND_RELEASE: drop UNET_ARG_A's TCPX context without a word to the
; peer and release the channel. Out: A=0.
CLEAR_AND_RELEASE
	LD	A,(UNET_ARG_A)
	CALL	@TCPX.SELECT_CONTEXT
	CALL	@TCPX.CLEAR_CONTEXT
	XOR	A
; RELEASE_WITH_STATUS: reached by fallthrough from CLEAR_AND_RELEASE above
; (keep them adjacent) and by jump from CLOSE_CHANNEL. In: A=status to
; report. Releases or re-arms the channel and returns that same A.
RELEASE_WITH_STATUS
	PUSH	AF
	CALL	RELEASE_OR_REARM
	POP	AF
	RET

; RELEASE_OR_REARM: mark UNET_ARG_A's channel free, or re-arm LISTEN when it
; is the connection LISTEN accepted. Called by CLOSE_CHANNEL and by F_RECV
; when the peer closes an ordinary or accepted connection on us.
; In: UNET_ARG_A = channel, its TCPX context already closed. Out: A=0, so a
; caller with a status to report saves it across the call.
RELEASE_OR_REARM
	CALL	IS_ACCEPTED_LISTEN
	JR	NC,.plain_close
	LD	HL,(UNET_LISTEN_PORT)
	LD	A,(UNET_LISTEN_CHANNEL)
	CALL	@TCPX.LISTEN
	XOR	A
	LD	(UNET_LISTEN_ACCEPTED),A
	LD	A,(UNET_LISTEN_CHANNEL)
	CALL	CH_STATE_PTR
	LD	(HL),3
	XOR	A
	RET
.plain_close
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),0
	XOR	A
	RET

; IS_ACCEPTED_LISTEN: does UNET_ARG_A name the channel LISTEN accepted?
; Out: CF=1 yes, CF=0 no. Trashes A/HL.
IS_ACCEPTED_LISTEN
	LD	A,(UNET_LISTEN_ACCEPTED)
	OR	A
	RET	Z			; CF=0 from OR A: nothing was accepted
	LD	A,(UNET_LISTEN_CHANNEL)
	LD	HL,UNET_ARG_A
	CP	(HL)
	JR	Z,.yes
	OR	A			; CF=0: some other channel
	RET
.yes
	SCF
	RET

; ------------------------------------------------------
; Function 9 - STATUS. A=channel, or 0xFF for the network-status form
; (memory-only: never touches hardware).
; ------------------------------------------------------
F_STATUS
	CP	0xFF
	JR	Z,.netstat
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	C,A			; the pend probe and the accept compare both
					; need the channel after HL is reused;
					; CH_STATE_PTR trashes only A/DE/HL
	CALL	CH_STATE_PTR
	LD	A,(HL)
	CP	3
	JR	Z,.listening
	OR	A
	LD	DE,0
	JR	Z,.chan_ready
	LD	DE,UNET_ST_CONN
	DEC	A			; connected(1)->0; a UDP channel(2) has no
	JR	NZ,.accept		; TCP pend slot to look at
	LD	HL,S11_CONTEXT0+@TCPX.CTX_PENDING_LEN
	BIT	0,C
	JR	Z,.pend_read
	LD	HL,S11_CONTEXT1+@TCPX.CTX_PENDING_LEN
.pend_read
	LD	A,(HL)
	INC	HL
	OR	(HL)
	JR	Z,.accept
	SET	2,E			; UNET_ST_RXPEND: TCPX buffered a segment
					; that arrived while no RECV was waiting
.accept
	LD	A,(UNET_LISTEN_ACCEPTED)
	OR	A
	JR	Z,.chan_ready
	LD	A,(UNET_LISTEN_CHANNEL)
	CP	C
	JR	NZ,.chan_ready
	SET	3,E			; UNET_ST_ACCEPT (keeps any pend bit)
	JR	.chan_ready
.listening
	LD	DE,UNET_ST_LISTEN
.chan_ready
	XOR	A
	RET
.netstat
	CALL	ENV_IS_UP
	JR	C,.notup
	LD	DE,1			; bit0: configured
	LD	A,(UNET_INITED)
	OR	A
	JR	Z,.cfg
	SET	1,E			; bit1: NETINIT done
.cfg
	XOR	A
	RET
.notup
	LD	DE,0
	LD	A,NERR_NONET
	JP	RET_A

; ------------------------------------------------------
; Function 10 - UDPOPEN. A=channel, DE=host ASCIIZ, IX=rport ASCIIZ,
; IY=lport ASCIIZ|0. P3a: literal IPv4 host only, like F_CONNECT -- a
; hostname arrives with RESOLVE's own DNS support. A zero/absent IY
; defaults the local port to the ephemeral range 0xC400+channel.
; ------------------------------------------------------
F_UDPOPEN
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	LD	(UNET_ARG_IY),IY
	CALL	CH_STATE_PTR
	LD	A,(HL)
	OR	A
	JP	NZ,RET_STATE
	LD	A,(UNET_INITED)
	OR	A
	JP	Z,RET_STATE
	LD	HL,(UNET_ARG_DE)
	CALL	CHECK_HOST_ARG
	JP	C,RET_PARAM
	CALL	RESOLVE_HOST
	JP	C,DNS_FAIL_TAIL
	LD	HL,(UNET_ARG_IX)
	CALL	CHECK_PORT_ARG
	JP	C,RET_PARAM
	LD	(UNET_UDP_RPORT),HL
	LD	HL,(UNET_ARG_IY)
	LD	A,H
	OR	L
	JR	Z,.udpo_default_lport
	CALL	CHECK_PORT_ARG
	JP	C,RET_PARAM
	JR	.udpo_have_lport
.udpo_default_lport
	LD	HL,0xC400
	LD	A,(UNET_ARG_A)
	ADD	A,L
	LD	L,A
.udpo_have_lport
	LD	(UNET_UDP_LPORT),HL
	CALL	RESOLVE_TARGET
	JP	C,RET_A
	; UDP_CTX_PTR hands the slot back in HL, and this copy goes INTO the
	; slot, so the slot has to be the LDIR destination: with HL left as the
	; source the channel's address and MAC are never stored, SELECT_UDP_CONTEXT
	; later loads the zeroed slot, and every datagram leaves for 0.0.0.0 at
	; MAC 00:00:00:00:00:00 while SEND still reports success.
	LD	A,(UNET_ARG_A)
	CALL	UDP_CTX_PTR
	EX	DE,HL			; DE = &slot, HL free for the sources
	LD	HL,UNET_CONNECT_IP
	LD	BC,4
	LDIR
	LD	HL,NET_RESULT_MAC
	LD	BC,6
	LDIR
	EX	DE,HL			; HL = &slot + 10 (the port pair)
	LD	DE,(UNET_UDP_RPORT)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	INC	HL
	LD	DE,(UNET_UDP_LPORT)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),2
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 11 - RESOLVE. DE=host ASCIIZ, IX=dest(>=16 bytes) -> A,
; dest="a.b.c.d",0. Accepts both a literal dotted quad and a hostname
; (DNSX.RESOLVE_OR_LITERAL, P3b); either way the binary result is
; reformatted back to text since a resolved hostname has no source text
; to echo.
; ------------------------------------------------------
F_RESOLVE
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	LD	A,(UNET_INITED)
	OR	A
	JP	Z,RET_STATE		; like CONNECT/PING: the parsers live in the cold overlay NETINIT loads
	LD	HL,(UNET_ARG_IX)
	LD	BC,16
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	HL,(UNET_ARG_DE)
	CALL	CHECK_HOST_ARG
	JP	C,RET_PARAM
	CALL	RESOLVE_HOST
	JP	C,DNS_FAIL_TAIL
	; Format the binary result back to text rather than copying the
	; caller's own validated source text: RESOLVE_OR_LITERAL accepts both a
	; literal dotted quad and a hostname, and either way leaves only the
	; binary answer, copied to UNET_CONNECT_IP by RESOLVE_HOST above.
	LD	HL,UNET_CONNECT_IP
	LD	DE,(UNET_ARG_IX)
	CALL	FORMAT_IPV4
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 12 - PING (one round trip). DE=host ASCIIZ, IY=timeout_ms ->
; A, DE=round-trip ms. P3a: literal IPv4 host only. Incoming ARP is
; ignored during the wait (a diagnostic call's brief window is not worth
; the extra code -- the requester simply retries).
; ------------------------------------------------------
F_PING
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IY),IY
	LD	A,(UNET_INITED)
	OR	A
	JP	Z,RET_STATE
	LD	HL,(UNET_ARG_DE)
	CALL	CHECK_HOST_ARG
	JP	C,RET_PARAM
	CALL	RESOLVE_HOST
	JP	C,DNS_FAIL_TAIL
	CALL	RESOLVE_TARGET
	JP	C,RET_A
	; Built in the (idle, at this point) RX buffer, not the small ARP-only
	; TX buffer: RESOLVE_TARGET's own ARP exchange (just above) is the
	; last thing to touch RX before this, and nothing after this reads it
	; -- same reasoning as tcp_transport.asm's TCPX_TX_BUFFER. The
	; Ethernet/ICMP/IPv4 frame assembly itself moved cold (PING_BUILD_ECHO,
	; unet509b_cold.asm) -- byte-for-byte the same wire format, every fixed
	; hot address reached through its own CCTX_* field instead.
	CALL	PING_BUILD_ECHO
	JP	C,RET_HW
	LD	(UNET_ARG_IX),DE		; identifier, recalled when a reply is checked
	LD	HL,STAGE9_RX_BUFFER
	CALL	@NETDRV.SEND_FRAME
	JP	C,RET_HW
	LD	BC,(UNET_ARG_IY)
	CALL	@NETTIME.START
	JP	C,RET_PARAM
.ping_poll
	CALL	@TCPX.CHECK_CANCEL
	JR	NC,.ping_no_cancel
	LD	A,NERR_CANCEL
	LD	DE,0
	JP	RET_A
.ping_no_cancel
	CALL	@NETDRV.RX_PENDING
	JR	NC,.ping_rx_ok
	LD	A,NERR_HW
	LD	DE,0
	JP	RET_A
.ping_rx_ok
	OR	A
	JR	Z,.ping_tick
	LD	HL,STAGE9_RX_BUFFER
	LD	BC,STAGE9_RX_CAPACITY
	CALL	@NETDRV.READ_FRAME
	JR	C,.ping_tick
	LD	(S9_RX_LENGTH),BC
	LD	A,(STAGE9_RX_BUFFER+12)
	CP	0x08
	JR	NZ,.ping_tick
	LD	A,(STAGE9_RX_BUFFER+13)
	OR	A
	JR	NZ,.ping_tick			; IPv4 only; ARP (0x0806) ignored too
	LD	A,(STAGE9_RX_BUFFER+23)
	CP	IPV4_PROTOCOL_ICMP
	JR	NZ,.ping_tick
	; IPv4+ICMP parsing and reply matching moved cold (PING_PARSE_REPLY,
	; unet509b_cold.asm) -- same accept/reject behaviour, CCTX_* fields
	; instead of the fixed hot addresses this used to touch directly.
	LD	DE,(UNET_ARG_IX)
	CALL	PING_PARSE_REPLY
	JR	C,.ping_tick
	LD	DE,(NETTIME_ELAPSED_MS)
	XOR	A
	JP	RET_A
.ping_tick
	CALL	@NETTIME.TICK
	JR	NC,.ping_poll
	LD	A,NERR_TIMEOUT
	LD	DE,0
	JP	RET_A

; ------------------------------------------------------
; SELECT_UDP_CONTEXT: In A=channel (already open as UDP). Copies
; UNET_UDP_CTX[A] into the udp_transport.asm scalars SEND/WAIT read (the
; module itself only ever tracks one connected tuple at a time). A
; datagram for the OTHER channel arriving during this channel's WAIT is
; dropped by UDP.PARSE's own port match -- documented in the plan.
; Trashes AF/BC/DE/HL. Moved cold: every address it touches is a fixed
; hot one, reached through its own CCTX_* field instead (NET_TARGET_IP/
; NET_RESULT_MAC already had one each; UDP_CTX_PTR's own UNET_UDP_CTX and
; S9_LOCAL_PORT -- +2/+4 reaches S9_REMOTE_PORT/S9_EXPECT_REMOTE_PORT --
; are new). The channel arrives in E, not A: A is COLD.RUN's own function
; code.
SELECT_UDP_CONTEXT
	LD	E,A
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_SELECT_UDP_CONTEXT
	JP	@COLD.RUN

; UDP_CTX_PTR: In A=channel. Out: HL=&UNET_UDP_CTX[channel]. Trashes DE.
UDP_CTX_PTR
	LD	E,A
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_UDP_CTX_PTR
	JP	@COLD.RUN

; ------------------------------------------------------
; Function 18 - LISTEN. A=channel, DE=local port (binary, 1..65535) -> A.
; Only one listening channel at a time; the target channel must be closed.
; ------------------------------------------------------
F_LISTEN
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	A,D
	OR	E
	JP	Z,RET_PARAM
	LD	A,(UNET_INITED)
	OR	A
	JP	Z,RET_STATE
	LD	A,(UNET_LISTEN_CHANNEL)
	CP	0xFF
	JP	NZ,RET_STATE
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	A,(HL)
	OR	A
	JP	NZ,RET_STATE
	LD	HL,(UNET_ARG_DE)
	LD	A,(UNET_ARG_A)
	CALL	@TCPX.LISTEN
	JP	C,RET_HW
	LD	A,(UNET_ARG_A)
	LD	(UNET_LISTEN_CHANNEL),A
	LD	HL,(UNET_ARG_DE)
	LD	(UNET_LISTEN_PORT),HL
	XOR	A
	LD	(UNET_LISTEN_ACCEPTED),A
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),3
	XOR	A
	JP	RET_A

; ------------------------------------------------------
; Function 19 - UNLISTEN. A=channel (the currently listening one) -> A.
; An already-accepted connection stays open as a normal channel; only the
; listener bookkeeping is cleared for it.
; ------------------------------------------------------
F_UNLISTEN
	IFDEF	TCPX_ASYNCSEND
	CALL	CHECK_ASYNC_PEND
	ENDIF
	CALL	CHECK_CHANNEL
	JP	C,RET_PARAM
	LD	(UNET_ARG_A),A
	LD	HL,UNET_LISTEN_CHANNEL
	CP	(HL)
	JP	NZ,RET_STATE
	LD	A,(UNET_LISTEN_ACCEPTED)
	OR	A
	JR	NZ,.already_accepted
	LD	A,(UNET_ARG_A)
	CALL	@TCPX.UNLISTEN
	LD	A,(UNET_ARG_A)
	CALL	CH_STATE_PTR
	LD	(HL),0
.already_accepted
	CALL	UNARM_LISTENER
	XOR	A
	RET

; ------------------------------------------------------
; Function 13/14 - RXPAUSE/RXRESUME. Genuine no-ops (UNET_CAP_RXFLOW is
; clear): the 3C509B buffers receive in its own on-card FIFO.
; ------------------------------------------------------
F_RXPAUSE
F_RXRESUME
	XOR	A
	RET

; ------------------------------------------------------
; Function 15 - GETINFO. A=field id, DE=dest, IX=max(incl NUL).
; Every field is a direct passthrough of the matching NET_* env string
; (already text; NETCFG/IFUP wrote it), so this needs no NETINIT.
; ------------------------------------------------------
F_GETINFO
	LD	(UNET_ARG_A),A
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM		; max=0 has no room for the NUL
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(UNET_ARG_A)
	OR	A
	JR	Z,.backend
	CP	INFO_FIELD_COUNT
	JR	NC,.empty
	LD	L,A
	LD	H,0
	DEC	HL
	ADD	HL,HL
	LD	DE,INFO_NAME_TABLE
	ADD	HL,DE
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	A,D
	OR	E
	JR	Z,.empty		; SSID / BAUD: no 3C509B equivalent
	EX	DE,HL			; HL = env var name
	LD	DE,S9_ENV_BUFFER
	CALL	ENV_GET_RAW
	JR	C,.empty
	LD	HL,S9_ENV_BUFFER
	JR	.copyout
.backend
	LD	HL,LIT_509B
	JR	.copyout
.empty
	LD	HL,LIT_EMPTY
.copyout
	LD	DE,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ------------------------------------------------------
; Function 16 - LASTERR. DE=dest, IX=max. Before the first failure the
; mutable template is rebuilt from live state. RET_A formats it at every
; failure; successful calls leave that snapshot untouched until the next
; failure replaces it.
; ------------------------------------------------------
F_LASTERR
	LD	(UNET_ARG_DE),DE
	LD	(UNET_ARG_IX),IX
	LD	HL,(UNET_ARG_IX)
	LD	A,H
	OR	L
	JP	Z,RET_PARAM
	LD	HL,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	CHECK_BUF_RANGE
	JP	C,RET_PARAM
	LD	A,(UNET_LAST_NERR)
	OR	A
	CALL	Z,BUILD_LASTERR
	LD	HL,LASTERR_BUF
	LD	DE,(UNET_ARG_DE)
	LD	BC,(UNET_ARG_IX)
	CALL	COPY_LIMITED
	XOR	A
	RET

; ------------------------------------------------------
; Function 17 - SETOPT. RXTRIG is a valid option id in the shared ABI
; that this backend simply has no hardware for (NERR_NOTSUP, not
; NERR_PARAM: the id itself is not garbage).
; ------------------------------------------------------
F_SETOPT
	CP	UNET_OPT_CANCELKEYS
	JR	Z,.cancelkeys
	CP	UNET_OPT_RXTRIG
	JP	Z,RET_NOTSUP
	CP	UNET_OPT_SENDSLICE
	JR	Z,.sendslice
	JP	RET_PARAM
.cancelkeys
	LD	A,D
	OR	E
	JR	Z,.store_cancel
	LD	A,1
.store_cancel
	LD	(UNET_CANCEL_MODE),A
	XOR	A
	RET
.sendslice
	LD	A,D
	OR	E
	JR	Z,.store_slice		; 0 = blocking, the default: no clamp
	LD	A,D
	OR	A
	JR	NZ,.store_slice		; DE >= 256 > 50: keep as-is
	LD	A,E
	CP	50
	JR	NC,.store_slice		; E >= 50: keep as-is
	LD	DE,50			; 1..49 -> clamp to the enforced minimum
.store_slice
	LD	(UNET_OPT_SLICE),DE
	XOR	A
	RET

; ======================================================
; Shared exits (the reserved export slots 20..23 jump straight to RET_NOTSUP). Reached via JP C / JP Z, so CF is cleared explicitly:
; every UNET function returns status in A with CF=0.
; ======================================================
RET_A					; A already set
	OR	A
	RET	Z
	LD	(UNET_LAST_NERR),A
	; BUILD_LASTERR uses the scratch register set but SEND/RECV return DE.
	; IY is deliberately its table cursor so the public IX result survives.
	PUSH	AF
	PUSH	DE
	CALL	BUILD_LASTERR
	POP	DE
	POP	AF
	RET
RET_PARAM
	LD	A,NERR_PARAM
	JR	RET_A
RET_NOTSUP
	LD	A,NERR_NOTSUP
	JR	RET_A
RET_NONET
	LD	A,NERR_NONET
	JR	RET_A
RET_HW
	LD	A,NERR_HW
	JR	RET_A
RET_STATE
	LD	A,NERR_STATE
	JR	RET_A

; ------------------------------------------------------
	IFDEF	TCPX_ASYNCSEND
; ------------------------------------------------------
; CHECK_ASYNC_PEND: refuse every transmitting/state-changing call except
; the resuming SEND itself while a SEND is suspended -- completing the
; transaction from elsewhere would lose its byte-count result, and a later
; SEND retry would duplicate stream bytes (see F_SEND's own resume path).
; RECV is deliberately NOT gated by this: it only ever serves already-
; buffered data or polls the NIC (which is how the suspended send's ACK
; gets discovered in the first place), never builds or sends anything.
; No pend: returns normally to the caller with A (the channel argument
; of CONNECT/CLOSE/UDPOPEN/LISTEN/UNLISTEN) untouched -- the flag is
; tested in place with INC/DEC (HL) for exactly that reason. A pend:
; drops the return into the F_ function and reports NERR_BUSY straight to
; the DLL's caller -- every call site is the first instruction of its F_
; function, with nothing on the stack to undo. Trashes HL (never an
; argument register in the UNET ABI).
; ------------------------------------------------------
CHECK_ASYNC_PEND
	LD	HL,UNET_APEND_ACTIVE
	INC	(HL)
	DEC	(HL)
	RET	Z
	POP	HL			; discard the return into the F_ function
	LD	A,NERR_BUSY
	JP	RET_A
	ENDIF

; ------------------------------------------------------
; CHECK_CHANNEL: CF=1 unless A is 0 or 1 (UNET_CAP_MULTICHAN: both valid).
; ------------------------------------------------------
CHECK_CHANNEL
	CP	2
	JR	NC,.bad
	OR	A
	RET
.bad
	SCF
	RET

; CH_STATE_PTR: In A=channel (0/1, already validated). Out: HL=&UNET_CH_STATE[A].
; Preserves A. Trashes DE.
CH_STATE_PTR
	LD	HL,UNET_CH_STATE
	LD	E,A
	LD	D,0
	ADD	HL,DE
	RET

; ------------------------------------------------------
; CHECK_STRARG: validate and copy a caller ASCIIZ argument (host/port text).
; In: HL=caller pointer, DE=internal destination, B=max content bytes
; (excluding the NUL unet.inc's own limit already counts in whole bytes).
;   Out: CF=1 invalid (bad window, or no NUL within B bytes); DE holds a
; NUL-terminated copy on success. Trashes A, B, HL; DE advances to the NUL.
; ------------------------------------------------------
CHECK_STRARG
.loop
	LD	A,B
	OR	A
	JR	Z,.bad
	CALL	CHECK_BUF
	JR	C,.bad
	LD	A,(HL)
	OR	A
	JR	Z,.done
	LD	(DE),A
	INC	DE
	INC	HL
	DEC	B
	JR	.loop
.done
	XOR	A
	LD	(DE),A
	OR	A
	RET
.bad
	SCF
	RET

; CHECK_HOST_ARG: validate a caller host argument and leave it WHERE THE
; CALLER PUT IT. In: HL=caller pointer. Out: CF=1 invalid, HL preserved.
; Trashes A, B, DE.
;
; The resolver must still be able to read this text after the network has
; run: RESOLVE_ROUTE's ARP exchange and then the DNS wait loop both read
; frames into STAGE9_RX_BUFFER, and every retry re-reads the name. This
; image has no other scratch area big enough for a 128-byte hostname --
; S9_ENV_BUFFER *is* that RX buffer, safe only for NETINIT, when nothing
; is receiving. A name staged there is overwritten by the ARP reply before
; BUILD_QUERY ever sees it, and the query goes out asking for whatever
; frame landed last. So the copy below exists only to run CHECK_STRARG's
; bounds-checked scan; its result is discarded and the caller's own
; pointer comes back in HL. The price is that the text must be readable
; during a cold call, which rules out window 0: COLD.RUN maps the overlay
; there, so a pointer into it would read the blob instead of the name.
CHECK_HOST_ARG
	LD	A,H
	AND	0xC0
	SCF
	RET	Z			; window 0 holds the overlay mid-call
	PUSH	HL
	LD	DE,S9_ENV_BUFFER
	LD	B,MAX_HOST_LEN
	CALL	CHECK_STRARG
	POP	HL
	RET

; CHECK_PORT_ARG: In HL=caller's port ASCIIZ pointer. Out: HL=parsed value
; (1..65535), CF=1 on any validation failure. Trashes A, B, C, DE.
CHECK_PORT_ARG
	LD	DE,S9_ENV_BUFFER
	LD	B,MAX_PORT_LEN
	CALL	CHECK_STRARG
	RET	C
	LD	HL,S9_ENV_BUFFER
	JR	PARSE_PORT

; PARSE_PORT: HL=ASCIIZ decimal string. Out: HL=value (1..65535), CF=1 on
; an empty string, a non-digit, overflow past 65535, or a literal zero
; (port 0 is not connectable). Trashes A, BC, DE. Pure register logic
; (no fixed hot address), so it moved cold entirely -- no CCTX needed.
PARSE_PORT
	LD	A,CFN_PARSE_PORT
	JP	@COLD.RUN

; ------------------------------------------------------
; FILL_COLD_CTX: point every COLD_CTX pointer field at this image's own
; resident scalars, once NETDRV/EL3 have published them. A compact relocatable
; pointer table is copied as one block; literal zero entries are the reserved
; CCTX slots and are never dereferenced by cold code.
; Every field the cold blob dereferences must be filled here, including the
; ones only one cold routine touches: an unset pointer reads as 0x0000,
; which inside a cold call is the blob's OWN dispatch entry point, not a
; harmless null -- BUILD_FRAME and PING_BUILD_ECHO both WRITE the IPv4
; identifier back, so a missing CCTX_IP_ID overwrites the two bytes the
; next COLD.RUN jumps to, with WIN0 remapped and interrupts off.
; check-stage14.pl cross-checks the two lists.
; ------------------------------------------------------
FILL_COLD_CTX
	LD	HL,COLD_CTX_INIT_TABLE
	LD	DE,UNET_COLD_CTX
	LD	BC,CCTX_SIZE
	LDIR
	RET

COLD_CTX_INIT_TABLE
	DW STAGE9_RX_BUFFER,NET_LOCAL_IP,NETDRV_STATION_MAC
	DW NET_TARGET_IP,NET_NEXT_HOP_IP,NET_RESULT_MAC,S9_IP_ID
	DW DNS_TRANSACTION_ID,DNS_RESULT_IP,S9_RX_PAYLOAD,S9_DRAIN_LEFT
	DW S9_IPV4_BUILD_DESC,S9_IPV4_PARSE_DESC,DNS_NAME_POINTER,S9_RX_LENGTH
	DW S11_FRAME_LENGTH,PING_ICMP_BUILD_DESC,PING_ICMP_REPLY_DESC
	DW UNET_UDP_CTX,S9_LOCAL_PORT,S11_STATE_BASE,S11_PENDING0,S11_CONTEXT0
	DW @EL3IO.RXS_SUM,@EL3IO.RX_PAYLOAD,@EL3IO.RX_PAYLOAD_SUM
	ASSERT $ - COLD_CTX_INIT_TABLE == CCTX_SIZE

; ------------------------------------------------------
; TEARDOWN_LINK: forced, idempotent teardown before (re-)bringing the link
; up in F_NETINIT. Aborting first (not a graceful close) matches the
; hardware reset about to happen: every open peer tuple is about to be
; invalidated anyway, so there is nothing an orderly FIN exchange buys.
; ------------------------------------------------------
TEARDOWN_LINK
	XOR	A
	CALL	@TCPX.ABORT
	LD	A,1
	CALL	@TCPX.ABORT
	CALL	@NETDRV.DONE
	CALL	@COLD.FREE
	XOR	A
	LD	(UNET_CH_STATE),A
	LD	(UNET_CH_STATE+1),A
	LD	(UNET_INITED),A
	CALL	UNARM_LISTENER
	RET

; CLOSE_LINK: close both channels for F_NETDONE/FINI, which leave the card
; and cold overlay up (unlike TEARDOWN_LINK above). The listener is unarmed
; first so neither channel is re-armed. Out: A = channel 1's NERR_* when it
; is not NERR_OK, otherwise channel 0's -- statuses, not flags, so they are
; chosen, never OR-ed (UNETRTL CLOSE_LINK). Trashes UNET_ARG_A.
CLOSE_LINK
	CALL	UNARM_LISTENER
	XOR	A
	LD	(UNET_ARG_A),A
	CALL	CLOSE_CHANNEL
	PUSH	AF
	LD	A,1
	LD	(UNET_ARG_A),A
	CALL	CLOSE_CHANNEL
	POP	BC
	OR	A
	RET	NZ
	LD	A,B
	RET

; UNARM_LISTENER: clear the "channel N is the listener"/"has accepted"
; bookkeeping without touching any TCPX context -- callers already close
; or reset the contexts themselves. Trashes A.
UNARM_LISTENER
	LD	A,0xFF
	LD	(UNET_LISTEN_CHANNEL),A
	XOR	A
	LD	(UNET_LISTEN_ACCEPTED),A
	RET

; ------------------------------------------------------
; CAPTURE_DIAG: snapshot a raw TCPX/NETDRV/EL3 failure code (in A) and the
; driver's own EL3_LAST_STAGE/EL3_LAST_STATUS for LASTERR. Preserves A;
; trashes BC/HL.
; ------------------------------------------------------
CAPTURE_DIAG
	LD	(UNET_TCP_LAST),A
	PUSH	AF
	LD	A,(EL3_LAST_STAGE)
	LD	(UNET_DIAG_EL3),A
	LD	HL,(EL3_LAST_STATUS)
	LD	(UNET_DIAG_EL3+1),HL
	POP	AF
	RET

; ------------------------------------------------------
; RESOLVE_TARGET: ARP-resolves UNET_CONNECT_IP (no cache, plan decision
; #6) via TCPX's own route resolver, reusing its scratch context (F_CONNECT
; instead goes through TCPX.OPEN, which does this internally). Shared by
; F_UDPOPEN and F_PING. Out: CF=0 success (NET_RESULT_MAC filled); CF=1
; with A already mapped to NERR_* (ready for a caller's JP C,RET_A).
; ------------------------------------------------------
RESOLVE_TARGET
	LD	IX,S11_CONTEXT_SCRATCH
	LD	HL,UNET_CONNECT_IP
	PUSH	IX
	POP	DE
	INC	DE
	LD	BC,4
	LDIR
	CALL	@TCPX.RESOLVE_ROUTE
	RET	NC
	CALL	MAP_CONNECT_FAIL
	SCF
	RET

; ------------------------------------------------------
; RESOLVE_HOST: In HL=the caller's own host text (already validated by
; CHECK_HOST_ARG), literal dotted quad or hostname, resolved into
; UNET_CONNECT_IP. The text stays where the caller put it -- see
; CHECK_HOST_ARG on why a copy inside this image cannot survive. Shared by
; F_CONNECT/F_UDPOPEN/F_RESOLVE/F_PING. Out: CF=0 success; CF=1 with A=raw
; DNSX.RESOLVE_OR_LITERAL failure code (ready for a caller's JP C,DNS_FAIL_TAIL).
; ------------------------------------------------------
RESOLVE_HOST
	CALL	@DNSX.RESOLVE_OR_LITERAL
	RET	C
	LD	HL,NET_TARGET_IP
	LD	DE,UNET_CONNECT_IP
	LD	BC,4
	LDIR
	RET

; ------------------------------------------------------
; MAP_DNS_FAIL: In A=raw DNSX.RESOLVE_OR_LITERAL failure code. Out: A=NERR_*.
; Shared tail for F_CONNECT/F_UDPOPEN/F_RESOLVE/F_PING's resolve call.
; ------------------------------------------------------
DNS_FAIL_TAIL
	CALL	MAP_DNS_FAIL
	JP	RET_A

; FORMAT_IPV4: HL=4-byte binary IP, DE=destination (>=16 bytes). Out:
; DE=past the terminating NUL. Pure register logic, no CCTX pointer needed.
FORMAT_IPV4
	LD	A,CFN_FORMAT_IPV4
	JP	@COLD.RUN

; PING_BUILD_ECHO/PING_PARSE_REPLY: F_PING's own frame assembly/parsing,
; moved cold (see unet509b_cold.asm's own header comment on each).
PING_BUILD_ECHO
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_PING_BUILD_ECHO
	JP	@COLD.RUN

PING_PARSE_REPLY
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_PING_PARSE_REPLY
	JP	@COLD.RUN
MAP_DNS_FAIL
	LD	E,A
	LD	A,CFN_MAP_DNS_FAIL
	JP	@COLD.RUN

; ------------------------------------------------------
; MAP_CONNECT_FAIL: In A=raw TCPX.OPEN failure code. Out: A=NERR_*.
; ------------------------------------------------------
; Moved cold past CAPTURE_DIAG (see MAP_RECV_FAIL's own comment on why the
; raw code goes into E, not A).
MAP_CONNECT_FAIL
	CALL	CAPTURE_DIAG
	LD	E,A
	LD	A,CFN_MAP_CONNECT_FAIL
	JP	@COLD.RUN

; ------------------------------------------------------
; MAP_SEND_FAIL: In A=raw TCPX.SEND failure code. Out: A=NERR_*.
; ------------------------------------------------------
MAP_SEND_FAIL
	CALL	CAPTURE_DIAG
	LD	E,A
	LD	A,CFN_MAP_SEND_FAIL
	JP	@COLD.RUN

; ------------------------------------------------------
; MAP_RECV_FAIL: In A=raw TCPX.RECV failure code (TCP_ERR_TIMEOUT is
; handled by the caller before this is reached). Out: A=NERR_*.
; ------------------------------------------------------
; Moved cold past CAPTURE_DIAG (which must stay hot -- EL3_LAST_STAGE/
; STATUS are fixed hot addresses): the raw code goes into E, since A is
; COLD.RUN's own function-code register.
MAP_RECV_FAIL
	CALL	CAPTURE_DIAG
	LD	E,A
	LD	A,CFN_MAP_RECV_FAIL
	JP	@COLD.RUN

; ------------------------------------------------------
; ENV_IS_UP: CF=0 iff NET_IP and NET_MAC are both published (the same
; "up" test STATUS(0xFF)/NETINIT use). Trashes A, BC, DE, HL.
; ------------------------------------------------------
ENV_IS_UP
	LD	HL,@S9APP.E_IP
	LD	DE,S9_ENV_BUFFER
	CALL	ENV_GET_RAW
	RET	C
	LD	HL,@S9APP.E_MAC
	LD	DE,S9_ENV_BUFFER
	JP	ENV_GET_RAW

; ------------------------------------------------------
; ENV_GET_RAW: HL=ASCIIZ env name, DE=256-byte destination.
;   Out: CF=0 found (value at DE); CF=1 absent (DE unspecified).
; Trashes A, BC.
; ------------------------------------------------------
ENV_GET_RAW
	PUSH	HL,DE
	LD	B,ENV_GET
	LD	C,DSS_ENVIRON
	RST	DSS
	POP	DE,HL
	OR	A
	JR	Z,.absent
	OR	A			; CF=0
	RET
.absent
	SCF
	RET

; ------------------------------------------------------
; Caller-buffer validation, matching the frozen ABI contract in
; unet.inc: WIN0 pointers are accepted; window 3 (the ISA aperture)
; and this DLL's own window are refused. Out: CF=1 invalid. Preserves
; BC, DE, HL.
; ------------------------------------------------------
CHECK_BUF
	LD	A,H
	AND	0xC0
	CP	0xC0
	JR	Z,.bad			; window 3: ISA
	LD	A,(UNET_WIN_BASE)
	XOR	H
	AND	0xC0
	JR	Z,.bad			; our own window
	OR	A
	RET
.bad
	SCF
	RET

; CHECK_BUF_RANGE: both ends of [HL, HL+BC-1] must be usable and the
; range must not wrap past 0xFFFF. BC=0 checks the start only.
;   Out: CF=1 invalid. Trashes A, BC, HL.
CHECK_BUF_RANGE
	CALL	CHECK_BUF
	RET	C
	LD	A,B
	OR	C
	RET	Z
	DEC	BC
	ADD	HL,BC
	RET	C
	JP	CHECK_BUF

; COPY_LIMITED: copy the ASCIIZ at HL to (DE), at most BC bytes
; INCLUDING the terminator. BC=0 is rejected by the callers. Deliberately
; HOT, although it is pure register logic: its two callers, GETINFO and
; LASTERR, are exactly the calls a consumer makes BEFORE NETINIT or right
; after NETINIT failed (NERR_NONET from the env check, or NERR_HW because
; the cold overlay itself could not be loaded) -- when COLD.RUN has nothing
; to run and would silently leave the caller's buffer untouched.
COPY_LIMITED
	DEC	BC
.loop
	LD	A,B
	OR	C
	JR	Z,.term
	LD	A,(HL)
	OR	A
	JR	Z,.term
	LD	(DE),A
	INC	HL
	INC	DE
	DEC	BC
	JR	.loop
.term
	XOR	A
	LD	(DE),A
	RET

; ------------------------------------------------------
; BUILD_LASTERR: format the shim's diagnostic scalars in the mutable literal
; LASTERR_BUF. The fixed bytes are part of the image and only the fields are
; rewritten, so the frozen line needs no second 43-byte BSS allocation.
;   "509B hw=0 st=00 nerr=00 tcp=00 el3=00/0000"
; ------------------------------------------------------
BUILD_LASTERR
	LD	A,(UNET_INITED)
	ADD	A,'0'
	LD	(LASTERR_BUF+8),A
	; The remaining six source bytes are contiguous. FORMAT_HEX_A advances DE;
	; this compact gap table skips the fixed labels. IY, not IX, is the source
	; cursor because RET_A must preserve RECV's public IX flags result.
	LD	IY,UNET_STAGE
	LD	DE,LASTERR_BUF+13
	LD	HL,LASTERR_GAPS
	LD	B,6
.field
	LD	A,(HL)
	ADD	A,E			; BSS_TX+13..41 cannot cross a page
	LD	E,A
	LD	A,(IY+0)
	INC	IY
	CALL	FORMAT_HEX_A
	INC	HL
	DJNZ	.field
	RET

; FORMAT_HEX_A: append A as two hex digits to (DE), DE advances.
; Trashes A. Preserves BC, HL.
FORMAT_HEX_A
	PUSH	AF
	RRCA
	RRCA
	RRCA
	RRCA
	CALL	.NIBBLE
	POP	AF
.NIBBLE
	AND	0x0F
	ADD	A,'0'
	CP	'9'+1
	JR	C,.PUT
	ADD	A,'A'-'9'-1
.PUT
	LD	(DE),A
	INC	DE
	RET

; ------------------------------------------------------
; GETINFO field-name table, indexed by (field_id - 1); 0 means "no env
; equivalent" (SSID/BAUD). Field 0 (backend tag) is handled separately.
; ------------------------------------------------------
INFO_FIELD_COUNT	EQU 13
INFO_NAME_TABLE
	DW @S9APP.E_IP		; 1  UNET_IF_IP
	DW @S9APP.E_MASK	; 2  UNET_IF_MASK
	DW @S9APP.E_GW		; 3  UNET_IF_GW
	DW @S9APP.E_MAC		; 4  UNET_IF_MAC
	DW @S9APP.E_DNS1	; 5  UNET_IF_DNS1
	DW @S9APP.E_DNS2	; 6  UNET_IF_DNS2
	DW N_NET_IPSRC		; 7  UNET_IF_IPSRC
	DW 0			; 8  UNET_IF_SSID  (no Wi-Fi)
	DW 0			; 9  UNET_IF_BAUD  (no UART)
	DW N_NET_NTP		; 10 UNET_IF_NTP
	DW N_NET_TZ		; 11 UNET_IF_TZ
	DW @S9APP.E_HW		; 12 UNET_IF_HW

LIT_509B	EQU @S9APP.V_509B
LIT_EMPTY	DB 0
LASTERR_BUF	DB "509B hw=0 st=00 nerr=00 tcp=00 el3=00/0000",0
	ASSERT $ - LASTERR_BUF == 43
LASTERR_GAPS	DB 0,6,5,5,1,0

N_NET_IPSRC	DB "NET_IP_SRC",0
N_NET_NTP	DB "NET_NTP",0
N_NET_TZ	DB "NET_TZ",0

; ------------------------------------------------------
; Shim-private scalars not shared with the driver stack.
; ------------------------------------------------------

	ENDMODULE

	ASSERT $ <= DLL_IMAGE_ORIGIN + 0x38C7
	ASSERT $ <= DLL_IMAGE_ORIGIN + 0x38B7	; retain at least 16 bytes spare
