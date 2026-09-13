; Executable UNET509B.DLL cold-overlay vectors for z88dk-ticks.
; SPDX-License-Identifier: BSD-3-Clause
;
; tools/test-stage14-asm.sh extracts the SHIPPED cold blob from the tail of
; build/UNET509B.DLL, drops it at 0x0000 (its real ORG, the address
; win0cold.asm's COLD.RUN maps it to and CALLs) and runs these vectors
; against it.
;
; Why this exists: the cold blob is where hot routines were REWRITTEN, not
; merely relocated -- fixed hot-BSS scratch became register/stack scratch,
; and each rewrite had to keep the register contract its hot caller still
; assumes. stage14_vectors.asm cannot reach any of it (it deliberately
; exercises only entry points that need neither card nor overlay), so
; nothing else executes a single cold instruction. A contract mismatch here
; looks like bad user input to the caller, not like a code defect: the
; original example is PARSE_HW, which read PARSE_U16's result from DE while
; PARSE_U16 returns it in HL, so every explicitly configured card was
; rejected as a malformed NET_HW and NETINIT answered NERR_NONET forever.
;
; Covered: the text parsers reached from LOAD_ACTIVE_CONFIG (the NETINIT
; path) plus the two argument helpers and the formatter the shim calls
; directly. The protocol codecs (ipv4/tcp/udp/icmp/ethernet) are INCLUDEd
; into the blob completely unmodified and are already covered by the stage
; 7-13 vectors in their hot form.

	DEVICE NOSLOT64K
; netdrv.inc aliases one of its codes to el3.inc's, and el3.inc is hot-only
; (hardware); unet509b_cold.asm resolves it the same way, with a matching EQU.
EL3_ERR_LINK_TIMEOUT	EQU 20
EL3_ERR_NOT_FOUND	EQU 3		; EL3_VALIDATE: product/manufacturer/MAC
EL3_ERR_CHECKSUM	EQU 5		; EL3_VALIDATE: a checksum lane

	INCLUDE "coldctx.inc"
	INCLUDE "unet.inc"		; NERR_* (frozen ABI constants)
	INCLUDE "netdrv.inc"		; NETDRV_ERR_*
	INCLUDE "tcp.inc"		; TCP_ERR_*
	INCLUDE "tcpctx.inc"		; cold fast-RX context fields

UNMAPPED_STATUS	EQU 0xFF		; no NERR_* mapping: must fall through to NERR_HW

TEST_RESULT	EQU 0x3F00		; first failing case number, 0 = all passed
TEST_COMPLETE	EQU 0x3F01		; 0xA5 once MARK_COMPLETE was reached
TEST_CASE	EQU 0x3F02
STACK_TOP	EQU 0x3E00
OUT_BUF		EQU 0x3D00		; parser/formatter destination
OUT_LEN		EQU 64
CCTX		EQU 0x3C00		; a stand-in COLD_CTX block for IX
FAKE_UDP_CTX	EQU 0x3C80		; where CCTX_UDP_CTX_BASE points
COLD_DEPTH	EQU 0x3F04		; word, deepest cold-call stack use (telemetry)

; Stand-ins for the hot BSS the PING/ARP/UDP cold routines reach through
; their own CCTX_* pointers. They are WRITTEN as well as read (NET_TARGET_IP
; and NET_RESULT_MAC are SELECT_UDP_CONTEXT's destinations and ARP_PARSE's
; output), so each one is a real RAM block here, refilled by FILL_CCTX.
RXB		EQU 0x5000		; frame buffer (CCTX_RX_BUF)
V_TARGET_IP	EQU 0x5800		; 4  NET_TARGET_IP
V_RESULT_MAC	EQU 0x5804		; 6  NET_RESULT_MAC
V_NEXTHOP_IP	EQU 0x580A		; 4  NET_NEXT_HOP_IP
V_IP_ID		EQU 0x5810		; 2  S9_IP_ID
V_FRAME_LEN	EQU 0x5812		; 2  S9_RX_LENGTH
V_S9_PORTS	EQU 0x5814		; 6  S9_LOCAL_PORT/REMOTE_PORT/EXPECT_REMOTE_PORT
V_IPB_DESC	EQU 0x5820		; 14 S9_IPV4_BUILD_DESC
V_IPP_DESC	EQU 0x5830		; 18 S9_IPV4_PARSE_DESC
V_ICMPB_DESC	EQU 0x5844		; 11 PING_ICMP_BUILD_DESC
V_ICMPR_DESC	EQU 0x5850		; 10 PING_ICMP_REPLY_DESC
V_SAVED_ID	EQU 0x585C		; 2  the identifier PING_BUILD_ECHO returned
V_SAVED_SP	EQU 0x585E		; 2  real SP, parked across the depth probe
V_DNS_NAME	EQU 0x5860		; 2  DNS_NAME_POINTER (holds a name pointer)
V_DNS_XID	EQU 0x5862		; 2  DNS_TRANSACTION_ID
V_DNS_RESULT	EQU 0x5864		; 4  DNS_RESULT_IP
V_DNS_PAYLOAD_END EQU 0x5868		; 2  S9_RX_PAYLOAD (parse scratch)
V_DNS_DRAIN	EQU 0x586A		; 1  S9_DRAIN_LEFT (parse scratch)
V_DNS_RX_LEN	EQU 0x586C		; 2  S11_FRAME_LENGTH (parse input)
V_LOCAL_IP	EQU 0x586E		; 4  a writable stand-in for NET_LOCAL_IP
V_TCP_STATE	EQU 0x5900		; compact DLL S11 state block (105 bytes)
V_TCP_CTX0	EQU 0x5980		; selected 40-byte TCP context
V_TCP_CTX1	EQU 0x59B0		; non-selected context
V_TCP_PENDING0	EQU 0x5A00		; two one-MSS durable pending slots
V_TCP_PENDING1	EQU V_TCP_PENDING0+TCP_MSS
V_TCP_DEST	EQU 0x6000		; visible caller buffer
V_TCP_SEED_EXPECT EQU 0x586F		; checksum seed expected by callback
V_TCP_FORCE_BAD	EQU 0x5871		; callback forces a checksum reject
V_TCP_RXS_SUM	EQU 0x5872		; hot EL3IO.RXS_SUM stand-in
V_TCP_SEED_ACTUAL EQU 0x5874		; seed observed by the checksum callback
V_TCP_CB_USED	EQU 0x5876		; 1=plain callback, 2=checksum callback

V_S11_SELECTED	EQU V_TCP_STATE+0x26
V_S11_MATCH	EQU V_TCP_STATE+0x28
V_S11_ACK_NOW	EQU V_TCP_STATE+0x48
V_S11_RX_DEST	EQU V_TCP_STATE+0x5F
V_S11_RX_FREE	EQU V_TCP_STATE+0x61
V_S11_RX_DELIVERED EQU V_TCP_STATE+0x63
V_S11_FAST_DIRECT EQU V_TCP_STATE+0x65
V_S11_FAST_BADSUM EQU V_TCP_STATE+0x5D

; Stack-depth probe: use the exact 0x3F80..0x3FFF reservation COLD.RUN maps.
; Its poisoned bottom byte doubles as the boundary canary.
PROBE_SP	EQU 0x4000
PROBE_FLOOR	EQU 0x3F80
PROBE_FILL	EQU 0xA5

	MACRO CASE n
	LD	A,n
	LD	(TEST_CASE),A
	ENDM

	; Call the cold blob's fixed entry point exactly as COLD.RUN does.
	MACRO COLD fn
	LD	A,fn
	CALL	0x0000
	ENDM

	MACRO EXPECT_NC
	JP	C,FAIL
	ENDM

	MACRO EXPECT_C
	JP	NC,FAIL
	ENDM

	MACRO EXPECT_HL value
	PUSH	DE
	LD	DE,value
	OR	A
	SBC	HL,DE
	POP	DE
	JP	NZ,FAIL
	ENDM

	MACRO EXPECT_A value
	CP	value
	JP	NZ,FAIL
	ENDM

	ORG	0x0000
	INCBIN	"cold.bin"

	ORG	VEC_BASE
TEST_START
	LD	SP,STACK_TOP
	LD	A,0xFF
	LD	(TEST_RESULT),A
	XOR	A
	LD	(TEST_COMPLETE),A
	LD	HL,0
	LD	(COLD_DEPTH),HL

; ------------------------------------------------------
; PARSE_U16 (CFN_PARSE_U16): HL="#" + 1..4 hex digits -> HL=value.
; stage9_app.asm's PARSE_HASH stub returns HL straight to
; LOAD_ACTIVE_CONFIG, which range-checks NET_IDPORT out of H and L.
; ------------------------------------------------------
	CASE	1
	LD	HL,T_HASH_110
	COLD	CFN_PARSE_U16
	EXPECT_NC
	EXPECT_HL 0x0110

	CASE	2
	LD	HL,T_HASH_300
	COLD	CFN_PARSE_U16
	EXPECT_NC
	EXPECT_HL 0x0300

	CASE	3			; one digit is still valid
	LD	HL,T_HASH_F
	COLD	CFN_PARSE_U16
	EXPECT_NC
	EXPECT_HL 0x000F

	CASE	4			; no '#' prefix
	LD	HL,T_NO_HASH
	COLD	CFN_PARSE_U16
	EXPECT_C

	CASE	5			; '#' with no digits
	LD	HL,T_HASH_ONLY
	COLD	CFN_PARSE_U16
	EXPECT_C

	CASE	6			; five digits overflow
	LD	HL,T_HASH_5DIG
	COLD	CFN_PARSE_U16
	EXPECT_C

	CASE	7			; non-hex digit
	LD	HL,T_HASH_BADDIG
	COLD	CFN_PARSE_U16
	EXPECT_C

; ------------------------------------------------------
; PARSE_HW (CFN_PARSE_HW): HL="<slot>/#<base>" -> A=slot, HL=base.
; stage9_app.asm's PARSE_HW stub stores A into NETDRV_CFG_SLOT and HL into
; NETDRV_CFG_BASE, so BOTH have to survive PARSE_U16 and BASE_ENCODE.
; ------------------------------------------------------
	CASE	10
	LD	HL,T_HW_0_300
	COLD	CFN_PARSE_HW
	EXPECT_NC
	EXPECT_A 0
	EXPECT_HL 0x0300

	CASE	11
	LD	HL,T_HW_1_210
	COLD	CFN_PARSE_HW
	EXPECT_NC
	EXPECT_A 1
	EXPECT_HL 0x0210

	CASE	12			; lowest accepted base
	LD	HL,T_HW_0_200
	COLD	CFN_PARSE_HW
	EXPECT_NC
	EXPECT_A 0
	EXPECT_HL 0x0200

	CASE	13			; highest accepted base
	LD	HL,T_HW_0_3E0
	COLD	CFN_PARSE_HW
	EXPECT_NC
	EXPECT_A 0
	EXPECT_HL 0x03E0

	CASE	14			; slot must be 0 or 1
	LD	HL,T_HW_2_300
	COLD	CFN_PARSE_HW
	EXPECT_C

	CASE	15			; missing '/' separator
	LD	HL,T_HW_NOSEP
	COLD	CFN_PARSE_HW
	EXPECT_C

	CASE	16			; base not on a 16-byte boundary
	LD	HL,T_HW_UNALIGNED
	COLD	CFN_PARSE_HW
	EXPECT_C

	CASE	17			; below EL3_BASE_MIN
	LD	HL,T_HW_LOW
	COLD	CFN_PARSE_HW
	EXPECT_C

	CASE	18			; above EL3_BASE_MAX
	LD	HL,T_HW_HIGH
	COLD	CFN_PARSE_HW
	EXPECT_C

; ------------------------------------------------------
; PARSE_IPV4 (CFN_PARSE_IPV4): HL=text, DE=4-byte destination.
; ------------------------------------------------------
	CASE	20
	CALL	CLEAR_OUT
	LD	HL,T_IP_HOST
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_NC
	LD	HL,X_IP_HOST
	LD	B,4
	CALL	EXPECT_BYTES

	CASE	21
	CALL	CLEAR_OUT
	LD	HL,T_IP_MASK
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_NC
	LD	HL,X_IP_MASK
	LD	B,4
	CALL	EXPECT_BYTES

	CASE	22
	CALL	CLEAR_OUT
	LD	HL,T_IP_ZERO
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_NC
	LD	HL,X_IP_ZERO
	LD	B,4
	CALL	EXPECT_BYTES

	CASE	23			; only three fields
	LD	HL,T_IP_SHORT
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_C

	CASE	24			; five fields
	LD	HL,T_IP_LONG
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_C

	CASE	25			; octet overflow
	LD	HL,T_IP_OVER
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_C

	CASE	26			; trailing garbage
	LD	HL,T_IP_TRAIL
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_C

	CASE	27			; empty string
	LD	HL,T_EMPTY
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_IPV4
	EXPECT_C

; ------------------------------------------------------
; PARSE_MAC (CFN_PARSE_MAC): HL=text, DE=6-byte destination.
; ------------------------------------------------------
	CASE	30
	CALL	CLEAR_OUT
	LD	HL,T_MAC_UPPER
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_MAC
	EXPECT_NC
	LD	HL,X_MAC
	LD	B,6
	CALL	EXPECT_BYTES

	CASE	31			; lowercase hex is accepted
	CALL	CLEAR_OUT
	LD	HL,T_MAC_LOWER
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_MAC
	EXPECT_NC
	LD	HL,X_MAC
	LD	B,6
	CALL	EXPECT_BYTES

	CASE	32			; only five octets
	LD	HL,T_MAC_SHORT
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_MAC
	EXPECT_C

	CASE	33			; dashes are not the separator
	LD	HL,T_MAC_DASH
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_MAC
	EXPECT_C

	CASE	34			; trailing byte after the sixth octet
	LD	HL,T_MAC_TRAIL
	LD	DE,OUT_BUF
	COLD	CFN_PARSE_MAC
	EXPECT_C

; ------------------------------------------------------
; PARSE_PORT (CFN_PARSE_PORT): HL=decimal text -> HL=1..65535.
; ------------------------------------------------------
	CASE	40
	LD	HL,T_PORT_80
	COLD	CFN_PARSE_PORT
	EXPECT_NC
	EXPECT_HL 80

	CASE	41
	LD	HL,T_PORT_MAX
	COLD	CFN_PARSE_PORT
	EXPECT_NC
	EXPECT_HL 65535

	CASE	42			; port 0 is not connectable
	LD	HL,T_PORT_ZERO
	COLD	CFN_PARSE_PORT
	EXPECT_C

	CASE	43			; 65536 overflows
	LD	HL,T_PORT_OVER
	COLD	CFN_PARSE_PORT
	EXPECT_C

	CASE	44			; empty string
	LD	HL,T_EMPTY
	COLD	CFN_PARSE_PORT
	EXPECT_C

	CASE	45			; non-digit
	LD	HL,T_PORT_BAD
	COLD	CFN_PARSE_PORT
	EXPECT_C

; ------------------------------------------------------
; FORMAT_IPV4 (CFN_FORMAT_IPV4): HL=4 binary bytes, DE=text destination.
; F_RESOLVE hands the result straight to the caller's own buffer.
; ------------------------------------------------------
	CASE	50
	CALL	CLEAR_OUT
	LD	HL,X_IP_HOST
	LD	DE,OUT_BUF
	COLD	CFN_FORMAT_IPV4
	LD	HL,T_IP_HOST
	CALL	EXPECT_TEXT

	CASE	51
	CALL	CLEAR_OUT
	LD	HL,X_IP_ZERO
	LD	DE,OUT_BUF
	COLD	CFN_FORMAT_IPV4
	LD	HL,T_IP_ZERO
	CALL	EXPECT_TEXT

	CASE	52			; three digits in every octet
	CALL	CLEAR_OUT
	LD	HL,X_IP_BCAST
	LD	DE,OUT_BUF
	COLD	CFN_FORMAT_IPV4
	LD	HL,T_IP_BCAST
	CALL	EXPECT_TEXT

; ------------------------------------------------------
; MAP_RECV_FAIL / MAP_CONNECT_FAIL (CFN_MAP_*): the hot trampolines move the
; raw library status into E because A carries the function code, so these
; are the sharpest test that DE survives dispatch.
; ------------------------------------------------------
	CASE	55
	LD	E,NETDRV_ERR_CANCELLED
	COLD	CFN_MAP_RECV_FAIL
	EXPECT_A NERR_CANCEL

	CASE	56
	LD	E,NETDRV_ERR_PARAMETER
	COLD	CFN_MAP_RECV_FAIL
	EXPECT_A NERR_PARAM

	CASE	57			; anything else: the channel is gone
	LD	E,TCP_ERR_RESET
	COLD	CFN_MAP_RECV_FAIL
	EXPECT_A NERR_CLOSED

	CASE	58
	LD	E,TCP_ERR_TIMEOUT
	COLD	CFN_MAP_CONNECT_FAIL
	EXPECT_A NERR_CONNECT

	CASE	59
	LD	E,NETDRV_ERR_CANCELLED
	COLD	CFN_MAP_CONNECT_FAIL
	EXPECT_A NERR_CANCEL

	CASE	60			; an unrecognized status is a hardware fault
	LD	E,UNMAPPED_STATUS
	COLD	CFN_MAP_CONNECT_FAIL
	EXPECT_A NERR_HW

; ------------------------------------------------------
; UDP_CTX_PTR (CFN_UDP_CTX_PTR): E=channel, IX=&COLD_CTX -> HL = the
; channel's slot in the shim's own UDP context array.
; ------------------------------------------------------
	CASE	65
	CALL	FILL_CCTX
	LD	IX,CCTX
	LD	E,0
	COLD	CFN_UDP_CTX_PTR
	EXPECT_HL FAKE_UDP_CTX

	CASE	66
	LD	IX,CCTX
	LD	E,1
	COLD	CFN_UDP_CTX_PTR
	EXPECT_HL FAKE_UDP_CTX+14

; ------------------------------------------------------
; ARP_BUILD_REQUEST (CFN_ARP_BUILD_REQUEST): HL=&target IP, DE=TX buffer,
; IX=&COLD_CTX -> BC=60, a complete padded request frame.
; ------------------------------------------------------
	CASE	70
	CALL	FILL_CCTX
	CALL	CLEAR_OUT
	LD	IX,CCTX
	LD	HL,FAKE_TARGET_IP
	LD	DE,OUT_BUF
	COLD	CFN_ARP_BUILD_REQUEST
	EXPECT_NC
	LD	H,B
	LD	L,C
	EXPECT_HL 60
	LD	HL,X_ARP_REQUEST
	LD	B,42			; the 18 pad bytes are zeroed, not compared
	CALL	EXPECT_BYTES

; ------------------------------------------------------
; PING_BUILD_ECHO (CFN_PING_BUILD_ECHO): IX=&COLD_CTX -> a whole
; Ethernet+IPv4+ICMP echo request in (CCTX_RX_BUF). F_PING hands BC
; straight to NETDRV.SEND_FRAME and DE straight into UNET_ARG_IX, so both
; have to survive ICMP.BUILD_ECHO, IPV4.BUILD and the descriptor helpers.
; ------------------------------------------------------
	CASE	100
	CALL	FILL_CCTX
	CALL	CLEAR_FRAME
	LD	IX,CCTX
	COLD	CFN_PING_BUILD_ECHO
	EXPECT_NC
	LD	(V_SAVED_ID),DE
	LD	H,B
	LD	L,C
	EXPECT_HL 42			; 14 Ethernet + 20 IPv4 + 8 ICMP

	CASE	101			; Ethernet header and the fixed IPv4 fields
	LD	HL,X_PING_HEAD
	LD	DE,RXB
	LD	B,24			; stops before the header checksum at +24
	CALL	EXPECT_RANGE

	CASE	102			; source and destination addresses
	LD	HL,X_PING_ADDRS
	LD	DE,RXB+26
	LD	B,8
	CALL	EXPECT_RANGE

	CASE	103			; the IPv4 header checksum covers what was built
	LD	HL,RXB+14
	LD	B,10
	CALL	CHECK_SUM16

	CASE	104			; ICMP type/code, sequence and checksum
	LD	HL,X_PING_ICMP
	LD	DE,RXB+34
	LD	B,2
	CALL	EXPECT_RANGE
	LD	HL,X_PING_SEQ
	LD	DE,RXB+40
	LD	B,2
	CALL	EXPECT_RANGE
	LD	HL,RXB+34
	LD	B,4
	CALL	CHECK_SUM16

	CASE	105			; the identifier on the wire is the one returned
	LD	A,(V_SAVED_ID+1)
	LD	HL,RXB+38
	CP	(HL)
	JP	NZ,FAIL			; big-endian: high byte first
	LD	A,(V_SAVED_ID)
	INC	HL
	CP	(HL)
	JP	NZ,FAIL

	CASE	106			; S9_IP_ID was consumed and advanced
	LD	HL,(V_IP_ID)
	EXPECT_HL 0x1235

; ------------------------------------------------------
; PING_PARSE_REPLY (CFN_PING_PARSE_REPLY): DE=the identifier the hot
; caller stashed, IX=&COLD_CTX, the frame in (CCTX_RX_BUF) and its length
; in (CCTX_DNS_FRAME_LEN). CF=0 only for a reply that belongs to us.
; ------------------------------------------------------
	CASE	110
	CALL	FILL_CCTX
	LD	HL,X_ECHO_REPLY
	CALL	LOAD_FRAME
	LD	IX,CCTX
	LD	DE,0xC5A7
	COLD	CFN_PING_PARSE_REPLY
	EXPECT_NC

	CASE	111			; another request's identifier
	CALL	FILL_CCTX
	LD	HL,X_ECHO_REPLY
	CALL	LOAD_FRAME
	LD	IX,CCTX
	LD	DE,0xC5A8
	COLD	CFN_PING_PARSE_REPLY
	EXPECT_C

	CASE	112			; an echo REQUEST, not a reply
	CALL	FILL_CCTX
	LD	HL,X_ECHO_REPLY
	CALL	LOAD_FRAME
	LD	A,8
	LD	(RXB+34),A
	LD	IX,CCTX
	LD	DE,0xC5A7
	COLD	CFN_PING_PARSE_REPLY
	EXPECT_C

	CASE	113			; addressed to another station on the segment
	CALL	FILL_CCTX
	LD	HL,X_ECHO_NOT_OURS
	CALL	LOAD_FRAME
	LD	IX,CCTX
	LD	DE,0xC5A7
	COLD	CFN_PING_PARSE_REPLY
	EXPECT_C

	CASE	114			; a truncated frame is short of its own IP length
	CALL	FILL_CCTX
	LD	HL,X_ECHO_REPLY
	CALL	LOAD_FRAME
	LD	HL,40
	LD	(V_FRAME_LEN),HL
	LD	IX,CCTX
	LD	DE,0xC5A7
	COLD	CFN_PING_PARSE_REPLY
	EXPECT_C

; ------------------------------------------------------
; ARP_PARSE (CFN_ARP_PARSE): HL=frame, BC=length, IX=&COLD_CTX.
; A=1 our reply (peer MAC copied to (CCTX_RESULT_MAC)), A=2 a request for
; us, CF=1 for anything else. This is the routine RESOLVE_TARGET's wait
; loop runs on every frame, so PING/CONNECT/UDPOPEN all reach it first.
; ------------------------------------------------------
	CASE	120
	CALL	FILL_CCTX
	CALL	POISON_RESULT_MAC
	LD	HL,X_ARP_REPLY
	LD	BC,42
	LD	IX,CCTX
	COLD	CFN_ARP_PARSE
	EXPECT_NC
	EXPECT_A 1

	CASE	121			; the peer MAC is what the route now uses
	LD	HL,X_PEER_MAC
	LD	DE,V_RESULT_MAC
	LD	B,6
	CALL	EXPECT_RANGE

	CASE	122			; a request for our address answers with A=2
	CALL	FILL_CCTX
	LD	HL,X_ARP_REQUEST_IN
	LD	BC,42
	LD	IX,CCTX
	COLD	CFN_ARP_PARSE
	EXPECT_NC
	EXPECT_A 2

	CASE	123			; a reply from some other host is not ours
	CALL	FILL_CCTX
	LD	HL,X_ARP_REPLY_OTHER
	LD	BC,42
	LD	IX,CCTX
	COLD	CFN_ARP_PARSE
	EXPECT_C

	CASE	124			; a runt frame is rejected on length alone
	CALL	FILL_CCTX
	LD	HL,X_ARP_REPLY
	LD	BC,41
	LD	IX,CCTX
	COLD	CFN_ARP_PARSE
	EXPECT_C

; ------------------------------------------------------
; ARP_BUILD_REPLY (CFN_ARP_BUILD_REPLY): HL=the request just parsed,
; DE=output, IX=&COLD_CTX -> BC=60. It reads the requester's addresses out
; of the very frame it answers, which is why it keeps its own TX buffer.
; ------------------------------------------------------
	CASE	130
	CALL	FILL_CCTX
	CALL	CLEAR_OUT
	LD	HL,X_ARP_REQUEST_IN
	LD	DE,OUT_BUF
	LD	IX,CCTX
	COLD	CFN_ARP_BUILD_REPLY
	EXPECT_NC
	LD	H,B
	LD	L,C
	EXPECT_HL 60
	LD	HL,X_ARP_REPLY_OUT
	LD	B,42			; the 18 pad bytes are zeroed, not compared
	CALL	EXPECT_BYTES

; ------------------------------------------------------
; SELECT_UDP_CONTEXT (CFN_SELECT_UDP_CONTEXT): E=channel, IX=&COLD_CTX.
; Copies one channel's tuple into the single set of scalars
; udp_transport.asm reads, so a wrong offset here sends channel 1's
; datagrams to channel 0's peer.
; ------------------------------------------------------
	CASE	140
	CALL	FILL_CCTX
	CALL	POISON_RESULT_MAC
	LD	HL,X_UDP_SLOT1
	LD	DE,FAKE_UDP_CTX+14
	LD	BC,14
	LDIR
	LD	IX,CCTX
	LD	E,1
	COLD	CFN_SELECT_UDP_CONTEXT
	LD	HL,X_UDP_SLOT1
	LD	DE,V_TARGET_IP
	LD	B,4
	CALL	EXPECT_RANGE

	CASE	141
	LD	HL,X_UDP_SLOT1+4
	LD	DE,V_RESULT_MAC
	LD	B,6
	CALL	EXPECT_RANGE

	CASE	142			; local port, then remote in both port slots
	LD	HL,(V_S9_PORTS)
	EXPECT_HL 0xC401
	LD	HL,(V_S9_PORTS+2)
	EXPECT_HL 0x1F90
	LD	HL,(V_S9_PORTS+4)
	EXPECT_HL 0x1F90

; ------------------------------------------------------
; Cold-stack depth. COLD.RUN runs the whole blob on a 128-byte private stack
; inside the DLL image (the consumer's own stack may live in the window
; WIN0 is about to be repointed at), and the bytes below it are the
; dispatcher's scalars and COLD_CTX itself -- an overflow would corrupt the
; pointer block the next cold call dereferences. Measured here over the
; deepest calls; test-stage14-asm.sh reports the number.
; ------------------------------------------------------
	CASE	150
	CALL	FILL_CCTX
	CALL	CLEAR_FRAME
	LD	IX,CCTX
	LD	A,CFN_PING_BUILD_ECHO
	CALL	PROBE_DEPTH

	CASE	151
	CALL	FILL_CCTX
	LD	HL,X_ECHO_REPLY
	CALL	LOAD_FRAME
	LD	IX,CCTX
	LD	DE,0xC5A7
	LD	A,CFN_PING_PARSE_REPLY
	CALL	PROBE_DEPTH

	CASE	152
	CALL	FILL_CCTX
	LD	HL,X_ARP_REPLY
	LD	BC,42
	LD	IX,CCTX
	LD	A,CFN_ARP_PARSE
	CALL	PROBE_DEPTH

	CASE	153			; leave at least half of the private stack unused
	LD	HL,(COLD_DEPTH)
	LD	DE,64
	OR	A
	SBC	HL,DE
	JP	NC,FAIL

; ------------------------------------------------------
; DLL fast-RX predicate: a normal established in-order data segment must go
; straight to the active caller buffer. The checksum callback also checks the
; pseudo/header seed the cold predicate computed before accepting payload.
; ------------------------------------------------------
	CASE	180
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,0x7BBD		; accumulator value before odd payload 0x4142,0x4300
	LD	(V_TCP_SEED_EXPECT),HL
	LD	IX,CCTX
	LD	IY,V_TCP_CTX0
	COLD	CFN_TCP_FAST_RECEIVE
	JR	C,.TCP_180_HANDLED
	CASE	181
	JP	FAIL
.TCP_180_HANDLED
	OR	A
	JR	Z,.TCP_180_STATUS_OK
	CASE	182
	JP	FAIL
.TCP_180_STATUS_OK
	CASE	183
	LD	A,(V_S11_FAST_DIRECT)
	CP	1
	JP	NZ,FAIL
	CASE	184
	LD	HL,(V_S11_RX_DELIVERED)
	EXPECT_HL 3
	CASE	185
	LD	HL,V_TCP_DEST
	LD	DE,X_TCP_PAYLOAD_ODD
	LD	B,3
	CALL	EXPECT_RANGE
	CASE	186
	LD	HL,V_TCP_CTX0+CTX_RCV_NXT
	LD	DE,X_TCP_NEXT_ODD
	LD	B,4
	CALL	EXPECT_RANGE
	LD	A,(V_TCP_CB_USED)
	IFDEF UNCHECKED_BUILD
	CP	1
	ELSE
	CP	2
	ENDIF
	JP	NZ,FAIL

	CASE	187			; even payload follows the same direct path
	LD	HL,X_TCP_EVEN
	CALL	SETUP_TCP_RX
	LD	HL,0x7B79
	LD	(V_TCP_SEED_EXPECT),HL
	LD	IX,CCTX
	LD	IY,V_TCP_CTX0
	COLD	CFN_TCP_FAST_RECEIVE
	JP	NC,FAIL
	OR	A
	JP	NZ,FAIL
	LD	A,(V_S11_FAST_DIRECT)
	CP	1
	JP	NZ,FAIL
	LD	HL,(V_S11_RX_DELIVERED)
	EXPECT_HL 4
	LD	HL,V_TCP_DEST
	LD	DE,X_TCP_PAYLOAD_EVEN
	LD	B,4
	CALL	EXPECT_RANGE
	LD	HL,V_TCP_CTX0+CTX_RCV_NXT
	LD	DE,X_TCP_NEXT_EVEN
	LD	B,4
	CALL	EXPECT_RANGE

	CASE	188			; safe rejects a bad sum; fast build accepts it
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,0x7BBD
	LD	(V_TCP_SEED_EXPECT),HL
	LD	A,1
	LD	(V_TCP_FORCE_BAD),A
	LD	IX,CCTX
	LD	IY,V_TCP_CTX0
	COLD	CFN_TCP_FAST_RECEIVE
	JP	NC,FAIL
	OR	A
	JP	NZ,FAIL
	IFDEF UNCHECKED_BUILD
	LD	A,(V_S11_FAST_DIRECT)
	CP	1
	JP	NZ,FAIL
	LD	HL,(V_S11_RX_DELIVERED)
	EXPECT_HL 3
	LD	A,(V_TCP_CB_USED)
	CP	1
	JP	NZ,FAIL			; unchecked build never called RX_PAYLOAD_SUM
	ELSE
	LD	A,(V_S11_FAST_DIRECT)
	OR	A
	JP	NZ,FAIL
	LD	HL,(V_S11_RX_DELIVERED)
	EXPECT_HL 0
	LD	HL,(V_S11_FAST_BADSUM)
	EXPECT_HL 1
	LD	HL,V_TCP_CTX0+CTX_RCV_NXT
	LD	DE,X_TCP_SEQUENCE
	LD	B,4
	CALL	EXPECT_RANGE
	LD	A,(V_TCP_CB_USED)
	CP	2
	JP	NZ,FAIL
	ENDIF

	CASE	189			; duplicate sequence remains on the slow path
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x40
	LD	(RXB+41),A
	CALL	EXPECT_TCP_SLOW

	CASE	190			; out-of-order sequence remains on the slow path
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x42
	LD	(RXB+41),A
	CALL	EXPECT_TCP_SLOW

	CASE	191			; FIN/SYN/RST and TCP options are never unchecked
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x19
	LD	(RXB+47),A
	CALL	EXPECT_TCP_SLOW
	CASE	192
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x1C
	LD	(RXB+47),A
	CALL	EXPECT_TCP_SLOW
	CASE	193
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x1A
	LD	(RXB+47),A
	CALL	EXPECT_TCP_SLOW
	CASE	194
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,0x60
	LD	(RXB+46),A
	CALL	EXPECT_TCP_SLOW

	CASE	195			; a pure ACK/zero-window probe has no fast payload
	LD	HL,X_TCP_ACK_ONLY
	CALL	SETUP_TCP_RX
	CALL	EXPECT_TCP_SLOW

	CASE	196			; WIN0 caller is hidden while the cold page is live
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,0x2000
	LD	(V_S11_RX_DEST),HL
	CALL	EXPECT_TCP_SLOW

	CASE	197			; small caller falls back to durable pending
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,2
	LD	(V_S11_RX_FREE),HL
	LD	HL,0x7BBD
	LD	(V_TCP_SEED_EXPECT),HL
	LD	IX,CCTX
	LD	IY,V_TCP_CTX0
	COLD	CFN_TCP_FAST_RECEIVE
	JP	NC,FAIL
	OR	A
	JP	NZ,FAIL
	LD	A,(V_S11_FAST_DIRECT)
	OR	A
	JP	NZ,FAIL
	LD	HL,(V_TCP_CTX0+CTX_PENDING_LEN)
	EXPECT_HL 3
	LD	A,(V_TCP_CTX0+CTX_EVENT)
	AND	EVENT_DATA
	JP	Z,FAIL
	LD	A,(V_S11_ACK_NOW)
	CP	1
	JP	NZ,FAIL
	LD	HL,V_TCP_PENDING0
	LD	DE,X_TCP_PAYLOAD_ODD
	LD	B,3
	CALL	EXPECT_RANGE

	CASE	198			; neither caller nor pending has enough space
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,2
	LD	(V_S11_RX_FREE),HL
	LD	HL,TCP_MSS-2
	LD	(V_TCP_CTX0+CTX_PENDING_LEN),HL
	CALL	EXPECT_TCP_SLOW

	CASE	199			; tuple for the other channel cannot bypass dispatch
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	A,81
	LD	(RXB+35),A		; peer source port 81 instead of context port 80
	CALL	EXPECT_TCP_SLOW

	CASE	200			; no selected context
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	IX,CCTX
	LD	IY,0
	COLD	CFN_TCP_FAST_RECEIVE
	JP	C,FAIL
	LD	A,(V_TCP_CB_USED)
	OR	A
	JP	NZ,FAIL

	CASE	201			; channel 1 uses only its own pending MSS
	LD	HL,X_TCP_ODD
	CALL	SETUP_TCP_RX
	LD	HL,V_TCP_CTX0
	LD	DE,V_TCP_CTX1
	LD	BC,40
	LDIR
	LD	HL,V_TCP_CTX1
	LD	(V_S11_SELECTED),HL
	LD	HL,0
	LD	(V_S11_RX_FREE),HL
	LD	HL,0x7BBD
	LD	(V_TCP_SEED_EXPECT),HL
	LD	IX,CCTX
	LD	IY,V_TCP_CTX1
	COLD	CFN_TCP_FAST_RECEIVE
	JP	NC,FAIL
	OR	A
	JP	NZ,FAIL
	LD	HL,(V_TCP_CTX1+CTX_PENDING_LEN)
	EXPECT_HL 3
	LD	HL,(V_TCP_CTX0+CTX_PENDING_LEN)
	EXPECT_HL 0
	LD	HL,V_TCP_PENDING1
	LD	DE,X_TCP_PAYLOAD_ODD
	LD	B,3
	CALL	EXPECT_RANGE

; ------------------------------------------------------
; The DNS codec (CFN_DNS_BUILD_FRAME / CFN_DNS_PARSE_FRAME /
; CFN_DNS_VALIDATE_NAME). This is the only cold path a caller reaches by
; passing a HOSTNAME instead of a literal address, so nothing else in the
; kit executes it, and a defect here surfaces on hardware as a plain
; RESOLVE timeout with no error of its own. BUILD_FRAME in particular is a
; rewrite, not a relocation: its fixed hot addresses became DNS_BUFPTR
; calls, and DNS_BUFPTR loads the buffer base into DE.
; ------------------------------------------------------
	CASE	160			; a query frame, checked field by field
	CALL	FILL_CCTX
	CALL	CLEAR_FRAME
	LD	HL,X_DNS_NAME
	LD	(V_DNS_NAME),HL
	LD	HL,0xBEEF
	LD	(V_DNS_XID),HL
	LD	IX,CCTX
	COLD	CFN_DNS_BUILD_FRAME
	JP	C,FAIL
	; "ns.test" encodes to 25 query bytes: 12 header, 3+5 labels, root,
	; QTYPE and QCLASS. The frame is that plus 14+20+8 of headers.
	LD	HL,(V_FRAME_LEN)
	EXPECT_HL 67
	LD	HL,X_DNS_FRAME		; Ethernet + IPv4 + UDP + DNS, byte for byte
	LD	DE,RXB
	LD	B,67
	CALL	EXPECT_RANGE
	LD	HL,RXB+14		; the IPv4 header validates against itself
	LD	B,10
	CALL	CHECK_SUM16
	LD	HL,(V_IP_ID)		; the identifier advanced, as PING's does
	EXPECT_HL 0x1235

	CASE	161			; UDP length tracks the frame, not the buffer
	; DNS_BUFPTR returns the pointer in HL and trashes DE, so a length
	; computed into DE BEFORE the call reaches the wire as the buffer's
	; own address -- a constant that survives any change of name. Assert
	; the invariant instead: UDP length is always frame length minus the
	; 14+20 bytes of Ethernet and IPv4 ahead of it.
	CALL	FILL_CCTX
	CALL	CLEAR_FRAME
	LD	HL,X_DNS_NAME_LONG
	LD	(V_DNS_NAME),HL
	LD	HL,0x0102
	LD	(V_DNS_XID),HL
	LD	IX,CCTX
	COLD	CFN_DNS_BUILD_FRAME
	JP	C,FAIL
	LD	A,(RXB+38)		; UDP length, big endian
	LD	H,A
	LD	A,(RXB+39)
	LD	L,A
	LD	DE,34
	ADD	HL,DE
	EX	DE,HL
	LD	HL,(V_FRAME_LEN)
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL
	LD	A,(RXB+16)		; IPv4 total length covers the same span
	LD	H,A
	LD	A,(RXB+17)
	LD	L,A
	LD	DE,14
	ADD	HL,DE
	EX	DE,HL
	LD	HL,(V_FRAME_LEN)
	OR	A
	SBC	HL,DE
	JP	NZ,FAIL

	CASE	162			; VALIDATE_NAME accepts and rejects
	CALL	FILL_CCTX
	LD	IX,CCTX
	LD	HL,X_DNS_NAME
	COLD	CFN_DNS_VALIDATE_NAME
	EXPECT_NC
	LD	IX,CCTX
	LD	HL,X_DNS_EMPTY
	COLD	CFN_DNS_VALIDATE_NAME
	EXPECT_C

	CASE	163			; PARSE_DNS_REPLY: first A/IN answer wins
	CALL	FILL_CCTX
	LD	HL,0xBEEF
	LD	(V_DNS_XID),HL
	LD	HL,0
	LD	(V_DNS_RESULT),HL
	LD	(V_DNS_RESULT+2),HL
	LD	HL,X_DNS_PAYLOAD
	LD	DE,RXB
	LD	BC,41
	LDIR
	LD	IX,CCTX
	LD	HL,RXB
	LD	BC,41
	COLD	CFN_DNS_PARSE_REPLY
	JP	C,FAIL
	LD	HL,X_IP_ANSWER
	LD	DE,V_DNS_RESULT
	LD	B,4
	CALL	EXPECT_RANGE

	CASE	164			; PARSE_REPLY_FRAME: a whole reply off the wire
	CALL	FILL_CCTX
	LD	HL,0xBEEF
	LD	(V_DNS_XID),HL
	LD	HL,0
	LD	(V_DNS_RESULT),HL
	LD	(V_DNS_RESULT+2),HL
	LD	HL,X_DNS_REPLY_FRAME
	LD	DE,RXB
	LD	BC,83
	LDIR
	LD	HL,83
	LD	(V_DNS_RX_LEN),HL
	LD	IX,CCTX
	COLD	CFN_DNS_PARSE_FRAME
	JP	C,FAIL
	LD	HL,X_IP_ANSWER
	LD	DE,V_DNS_RESULT
	LD	B,4
	CALL	EXPECT_RANGE

	CASE	165			; a reply for another station is not ours
	CALL	FILL_CCTX
	LD	HL,0xBEEF
	LD	(V_DNS_XID),HL
	LD	HL,X_DNS_REPLY_FRAME
	LD	DE,RXB
	LD	BC,83
	LDIR
	LD	HL,83
	LD	(V_DNS_RX_LEN),HL
	LD	HL,X_IP_OTHER		; the frame is addressed to X_IP_HOST
	LD	DE,V_LOCAL_IP
	LD	BC,4
	LDIR
	LD	HL,V_LOCAL_IP
	LD	(CCTX+CCTX_LOCAL_IP),HL
	LD	IX,CCTX
	COLD	CFN_DNS_PARSE_FRAME
	EXPECT_C

; ------------------------------------------------------
; EL3_VALIDATE (CFN_EL3_VALIDATE): HL=64-word EEPROM image (little-endian
; words, as EEPROM_BUFFER holds it), DE=6-byte MAC destination. This is the
; DLL's own rewrite of the hot VALIDATE -- NETINIT accepts or rejects the
; card here -- and no vector executed it before these. Both physical dumps
; must pass with the MAC in label order; a product ID that is neither
; verified value must be refused before the checksums run; a corrupted
; vital-lane word must still fail the secondary checksum.
; ------------------------------------------------------
	CASE	170			; 3C509B-TPO, product 9550, EA=0020AF5D698B
	CALL	CLEAR_OUT
	LD	HL,X_EEPROM_TPO
	LD	DE,OUT_BUF
	COLD	CFN_EL3_VALIDATE
	EXPECT_NC
	LD	HL,X_MAC_TPO
	LD	B,6
	CALL	EXPECT_BYTES

	CASE	171			; 3C509B-TP, product 9050, EA=0020AF4BAB97
	CALL	CLEAR_OUT
	LD	HL,X_EEPROM_TP
	LD	DE,OUT_BUF
	COLD	CFN_EL3_VALIDATE
	EXPECT_NC
	LD	HL,X_MAC_TP
	LD	B,6
	CALL	EXPECT_BYTES

	CASE	172			; product 9150: neither pinned value
	LD	HL,X_EEPROM_TP
	LD	DE,RXB
	LD	BC,128
	LDIR
	LD	A,0x91			; high byte of word 03: 9050 -> 9150
	LD	(RXB+7),A
	LD	HL,RXB
	LD	DE,OUT_BUF
	COLD	CFN_EL3_VALIDATE
	EXPECT_C
	EXPECT_A EL3_ERR_NOT_FOUND

	CASE	173			; word 18 is in the vital lane of word 17
	LD	HL,X_EEPROM_TP
	LD	DE,RXB
	LD	BC,128
	LDIR
	LD	A,(RXB+0x18*2)
	XOR	1
	LD	(RXB+0x18*2),A
	LD	HL,RXB
	LD	DE,OUT_BUF
	COLD	CFN_EL3_VALIDATE
	EXPECT_C
	EXPECT_A EL3_ERR_CHECKSUM

; ------------------------------------------------------
; An out-of-range function code must be a no-op, not a wild jump.
; ------------------------------------------------------
	CASE	90
	LD	A,CFN_COUNT
	CALL	0x0000
	CASE	91
	LD	A,0xFF
	CALL	0x0000

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
TEST_DONE
	JP	TEST_DONE

; ------------------------------------------------------
; Helpers
; ------------------------------------------------------
; Point the COLD_CTX fields these vectors exercise at local fixtures.
FILL_CCTX
	LD	HL,X_MAC
	LD	(CCTX+CCTX_STATION_MAC),HL
	LD	HL,X_IP_HOST
	LD	(CCTX+CCTX_LOCAL_IP),HL
	LD	HL,FAKE_UDP_CTX
	LD	(CCTX+CCTX_UDP_CTX_BASE),HL
	LD	HL,RXB
	LD	(CCTX+CCTX_RX_BUF),HL
	LD	HL,V_TARGET_IP
	LD	(CCTX+CCTX_TARGET_IP),HL
	LD	HL,V_NEXTHOP_IP
	LD	(CCTX+CCTX_NEXT_HOP_IP),HL
	LD	HL,V_RESULT_MAC
	LD	(CCTX+CCTX_RESULT_MAC),HL
	LD	HL,V_IP_ID
	LD	(CCTX+CCTX_IP_ID),HL
	LD	HL,V_FRAME_LEN
	LD	(CCTX+CCTX_DNS_FRAME_LEN),HL
	LD	HL,V_IPB_DESC
	LD	(CCTX+CCTX_DNS_IP_BUILD_DESC),HL
	LD	HL,V_IPP_DESC
	LD	(CCTX+CCTX_DNS_IP_PARSE_DESC),HL
	LD	HL,V_ICMPB_DESC
	LD	(CCTX+CCTX_PING_BUILD_DESC),HL
	LD	HL,V_ICMPR_DESC
	LD	(CCTX+CCTX_PING_REPLY_DESC),HL
	LD	HL,V_S9_PORTS
	LD	(CCTX+CCTX_S9_LOCAL_PORT),HL
	LD	HL,V_DNS_NAME
	LD	(CCTX+CCTX_DNS_NAME_PTR),HL
	LD	HL,V_DNS_XID
	LD	(CCTX+CCTX_DNS_XID),HL
	LD	HL,V_DNS_RESULT
	LD	(CCTX+CCTX_DNS_RESULT),HL
	LD	HL,V_DNS_PAYLOAD_END
	LD	(CCTX+CCTX_DNS_PAYLOAD_END),HL
	LD	HL,V_DNS_DRAIN
	LD	(CCTX+CCTX_DNS_DRAIN),HL
	LD	HL,V_DNS_RX_LEN
	LD	(CCTX+CCTX_DNS_RX_LEN),HL
	LD	HL,V_TCP_STATE
	LD	(CCTX+CCTX_TCP_STATE_BASE),HL
	LD	HL,V_TCP_PENDING0
	LD	(CCTX+CCTX_TCP_PENDING0),HL
	LD	HL,V_TCP_CTX0
	LD	(CCTX+CCTX_TCP_CONTEXT0),HL
	LD	HL,V_TCP_RXS_SUM
	LD	(CCTX+CCTX_EL3_RXS_SUM),HL
	LD	HL,TCP_RX_PLAIN_STUB
	LD	(CCTX+CCTX_CB_RX_PAYLOAD),HL
	LD	HL,TCP_RX_SUM_STUB
	LD	(CCTX+CCTX_CB_RX_PAYLOAD_SUM),HL
	; The peer the route already resolved to, and a fresh IP identifier.
	LD	HL,X_IP_PEER
	LD	DE,V_TARGET_IP
	LD	BC,4
	LDIR
	LD	HL,X_IP_PEER
	LD	DE,V_NEXTHOP_IP
	LD	BC,4
	LDIR
	LD	HL,X_PEER_MAC
	LD	DE,V_RESULT_MAC
	LD	BC,6
	LDIR
	LD	HL,0x1234
	LD	(V_IP_ID),HL
	RET

; HL=60-byte TCP fixture. Build one established selected context and an active
; visible caller-buffer scope around it.
SETUP_TCP_RX
	PUSH	HL
	CALL	FILL_CCTX
	LD	HL,V_TCP_STATE
	LD	BC,0x69
	CALL	CLEAR_BLOCK
	LD	HL,V_TCP_CTX0
	LD	BC,80
	CALL	CLEAR_BLOCK
	LD	HL,V_TCP_PENDING0
	LD	BC,1072
	CALL	CLEAR_BLOCK
	LD	HL,V_TCP_DEST
	LD	BC,64
	CALL	CLEAR_BLOCK
	POP	HL
	LD	DE,RXB
	LD	BC,60
	LDIR
	LD	HL,60
	LD	(V_DNS_RX_LEN),HL
	LD	HL,V_TCP_CTX0
	LD	(V_S11_SELECTED),HL
	LD	HL,V_TCP_DEST
	LD	(V_S11_RX_DEST),HL
	LD	HL,64
	LD	(V_S11_RX_FREE),HL
	LD	A,TCP_STATE_ESTABLISHED
	LD	(V_TCP_CTX0+CTX_STATE),A
	LD	HL,X_IP_PEER
	LD	DE,V_TCP_CTX0+CTX_REMOTE_IP
	LD	BC,4
	LDIR
	LD	HL,80
	LD	(V_TCP_CTX0+CTX_REMOTE_PORT),HL
	LD	HL,0xD058
	LD	(V_TCP_CTX0+CTX_LOCAL_PORT),HL
	LD	HL,X_TCP_ACK
	LD	DE,V_TCP_CTX0+CTX_SND_NXT
	LD	BC,4
	LDIR
	LD	HL,X_TCP_SEQUENCE
	LD	DE,V_TCP_CTX0+CTX_RCV_NXT
	LD	BC,4
	LDIR
	XOR	A
	LD	(V_TCP_FORCE_BAD),A
	LD	(V_TCP_CB_USED),A
	RET

; HL=start, BC=count (>0). Clear a fixture block without assuming DSS-zeroed
; memory, matching the real loader's arbitrary-page-content tests.
CLEAR_BLOCK
	LD	D,H
	LD	E,L
	INC	DE
	DEC	BC
	LD	(HL),0
	LDIR
	RET

; The caller has prepared a header that must stay on WAIT_LOOP's established
; slow path.  Prove the predicate neither consumed FIFO bytes nor committed
; transport state; PROCESS_FRAME is deliberately outside this cold-only test.
EXPECT_TCP_SLOW
	LD	IX,CCTX
	LD	IY,V_TCP_CTX0
	COLD	CFN_TCP_FAST_RECEIVE
	JP	C,FAIL
	LD	A,(V_TCP_CB_USED)
	OR	A
	JP	NZ,FAIL
	LD	A,(V_S11_FAST_DIRECT)
	OR	A
	JP	NZ,FAIL
	LD	HL,(V_S11_RX_DELIVERED)
	EXPECT_HL 0
	LD	HL,V_TCP_CTX0+CTX_RCV_NXT
	LD	DE,X_TCP_SEQUENCE
	LD	B,4
	JP	EXPECT_RANGE

; Hot callback stand-ins used by the separately assembled cold predicate.
; They copy from the simulated FIFO tail at RXB+54, then the SUM version
; validates the seed and publishes either the clean FFFF accumulator or a
; deliberately bad result.
TCP_RX_PLAIN_STUB
	LD	A,1
	LD	(V_TCP_CB_USED),A
	LD	HL,RXB+54
	LDIR
	XOR	A
	RET

TCP_RX_SUM_STUB
	LD	A,2
	LD	(V_TCP_CB_USED),A
	LD	HL,RXB+54
	LDIR
	LD	HL,(V_TCP_SEED_EXPECT)
	LD	DE,(V_TCP_RXS_SUM)
	LD	(V_TCP_SEED_ACTUAL),DE
	OR	A
	SBC	HL,DE
	JR	NZ,.bad
	LD	A,(V_TCP_FORCE_BAD)
	OR	A
	JR	NZ,.bad
	LD	HL,0xFFFF
	JR	.store
.bad
	LD	HL,0
.store
	LD	(V_TCP_RXS_SUM),HL
	XOR	A
	RET

; 0xCC over NET_RESULT_MAC, so a copy that never happens cannot pass by
; matching what FILL_CCTX already put there.
POISON_RESULT_MAC
	LD	HL,V_RESULT_MAC
	LD	B,6
	LD	A,0xCC
.loop
	LD	(HL),A
	INC	HL
	DJNZ	.loop
	RET

; 128 bytes: enough for the 42-byte ARP/ICMP fixtures and for the DNS
; query frame, which runs to 67 bytes plus whatever a longer name adds.
CLEAR_FRAME
	LD	HL,RXB
	LD	DE,RXB+1
	LD	BC,127
	LD	(HL),0xCC
	LDIR
	RET

; HL=a 42-byte frame fixture -> copied into RXB, length recorded where
; CCTX_DNS_FRAME_LEN points (PING's own S9_RX_LENGTH).
LOAD_FRAME
	LD	DE,RXB
	LD	BC,42
	LDIR
	LD	HL,42
	LD	(V_FRAME_LEN),HL
	RET

; HL=expected bytes, DE=actual, B=count.
EXPECT_RANGE
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAIL
	INC	HL
	INC	DE
	DJNZ	EXPECT_RANGE
	RET

; HL=start, B=word count. The one's-complement sum of a header that
; carries its own checksum is 0xFFFF; this checks the built frame against
; itself instead of against a hand-computed constant.
CHECK_SUM16
	LD	DE,0
.loop
	PUSH	BC
	LD	C,(HL)
	INC	HL
	LD	B,(HL)
	INC	HL
	EX	DE,HL
	ADD	HL,BC
	JR	NC,.no_carry
	INC	HL
.no_carry
	EX	DE,HL
	POP	BC
	DJNZ	.loop
	LD	A,D
	AND	E
	CP	0xFF
	JP	NZ,FAIL
	RET

; A=cold function code, arguments already in registers. Runs the call on the
; poisoned actual cold-stack reservation and keeps the deepest use seen so
; far in COLD_DEPTH. Touching its bottom canary measures as 128 and fails.
PROBE_DEPTH
	PUSH	AF
	LD	HL,PROBE_FLOOR
	LD	(HL),PROBE_FILL
	PUSH	DE
	LD	DE,PROBE_FLOOR+1
	LD	BC,PROBE_SP-PROBE_FLOOR-1
	LDIR
	POP	DE
	POP	AF
	LD	(V_SAVED_SP),SP
	LD	SP,PROBE_SP
	CALL	0x0000
	LD	SP,(V_SAVED_SP)
	; Walk up from the floor to the first byte the call left untouched.
	LD	HL,PROBE_FLOOR
	LD	BC,PROBE_SP-PROBE_FLOOR
.scan
	LD	A,(HL)
	CP	PROBE_FILL
	JR	NZ,.found
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.scan
	RET				; nothing written at all
.found
	EX	DE,HL
	LD	HL,PROBE_SP
	OR	A
	SBC	HL,DE			; HL = depth in bytes
	LD	DE,(COLD_DEPTH)
	OR	A
	SBC	HL,DE
	RET	C			; not deeper than what is already recorded
	ADD	HL,DE
	LD	(COLD_DEPTH),HL
	RET

CLEAR_OUT
	PUSH	HL,DE,BC
	LD	HL,OUT_BUF
	LD	B,OUT_LEN
	LD	A,0xCC
.loop
	LD	(HL),A
	INC	HL
	DJNZ	.loop
	POP	BC,DE,HL
	RET

; HL=expected bytes, B=count; compares against OUT_BUF.
EXPECT_BYTES
	LD	DE,OUT_BUF
.loop
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAIL
	INC	HL
	INC	DE
	DJNZ	.loop
	RET

; HL=expected ASCIIZ text; compares against OUT_BUF including the NUL.
EXPECT_TEXT
	LD	DE,OUT_BUF
.loop
	LD	A,(DE)
	CP	(HL)
	JP	NZ,FAIL
	OR	A
	RET	Z
	INC	HL
	INC	DE
	JR	.loop

; ------------------------------------------------------
; Fixtures
; ------------------------------------------------------
T_EMPTY		DB 0

T_HASH_110	DB "#110",0
T_HASH_300	DB "#300",0
T_HASH_F	DB "#F",0
T_NO_HASH	DB "110",0
T_HASH_ONLY	DB "#",0
T_HASH_5DIG	DB "#12345",0
T_HASH_BADDIG	DB "#30G",0

T_HW_0_300	DB "0/#300",0
T_HW_1_210	DB "1/#210",0
T_HW_0_200	DB "0/#200",0
T_HW_0_3E0	DB "0/#3E0",0
T_HW_2_300	DB "2/#300",0
T_HW_NOSEP	DB "0#300",0
T_HW_UNALIGNED	DB "0/#308",0
T_HW_LOW	DB "0/#1F0",0
T_HW_HIGH	DB "0/#3F0",0

T_IP_HOST	DB "192.168.7.21",0
; The two physical cards' EEPROMs as EL3EEP printed them (word n = Address(2n)
; high byte, Address(2n+1) low byte), stored little-endian like EEPROM_BUFFER.
; 3C509B-TPO, assembly 03-0020-002 rev 3, read 2026-09-08.
X_EEPROM_TPO
	DW 0x0020,0xAF5D,0x698B,0x9550,0xB434,0x0041,0x4A41,0x6D50
	DW 0x0010,0x3000,0x0020,0xAF5D,0x698B,0x1310,0x0000,0x3223
	DW 0x2083,0x0000,0x0000,0x0004,0x0001,0x0000,0x0000,0x0205
	DW 0x6D50,0x9550,0x698B,0xAF5D,0x0A5B,0x1010,0x1982,0x3300
	DW 0x6F43,0x206D,0x4333,0x3035,0x4239,0x4520,0x6874,0x7265
	DW 0x694C,0x6B6E,0x4920,0x4949,0x5015,0x506D,0x0295,0x411C
	DW 0x80D0,0x22F7,0x9EA8,0x0147,0x0210,0x03E0,0x1010,0x3779
	DW 0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
X_MAC_TPO	DB 0x00,0x20,0xAF,0x5D,0x69,0x8B
; 3C509B-TP, assembly 03-0021-201 rev A, read 2026-09-13.
X_EEPROM_TP
	DW 0x0020,0xAF4B,0xAB97,0x9050,0xBE3D,0x0041,0x4741,0x6D50
	DW 0x0010,0x3000,0x0020,0xAF4B,0xAB97,0x1310,0x0000,0x3923
	DW 0x2083,0x0000,0x0000,0x0004,0x0001,0x0000,0x0000,0x4505
	DW 0x6D50,0x9050,0xAB97,0xAF4B,0x0ADF,0x1010,0x1982,0x3300
	DW 0x6F43,0x206D,0x4333,0x3035,0x4239,0x4520,0x6874,0x7265
	DW 0x694C,0x6B6E,0x4920,0x4949,0x5015,0x506D,0x0290,0x411C
	DW 0x80D0,0x22F7,0x9EA8,0x0147,0x0210,0x03E0,0x1010,0x3C79
	DW 0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000
X_MAC_TP	DB 0x00,0x20,0xAF,0x4B,0xAB,0x97

X_IP_HOST	DB 192,168,7,21
T_IP_MASK	DB "255.255.255.0",0
X_IP_MASK	DB 255,255,255,0
T_IP_ZERO	DB "0.0.0.0",0
X_IP_ZERO	DB 0,0,0,0
T_IP_BCAST	DB "255.255.255.255",0
X_IP_BCAST	DB 255,255,255,255
T_IP_SHORT	DB "1.2.3",0
T_IP_LONG	DB "1.2.3.4.5",0
T_IP_OVER	DB "256.1.1.1",0
T_IP_TRAIL	DB "1.2.3.4x",0

T_MAC_UPPER	DB "00:20:AF:12:34:56",0
T_MAC_LOWER	DB "00:20:af:12:34:56",0
X_MAC		DB 0x00,0x20,0xAF,0x12,0x34,0x56
T_MAC_SHORT	DB "00:20:AF:12:34",0
T_MAC_DASH	DB "00-20-AF-12-34-56",0
T_MAC_TRAIL	DB "00:20:AF:12:34:56:",0

T_PORT_80	DB "80",0
T_PORT_MAX	DB "65535",0
T_PORT_ZERO	DB "0",0
T_PORT_OVER	DB "65536",0
T_PORT_BAD	DB "8o",0

FAKE_TARGET_IP	DB 192,168,7,44
; Ethernet + ARP request: broadcast, station MAC, EtherType, fixed ARP
; preamble, SHA, SPA, zeroed THA, TPA. The 18 trailing pad bytes are not
; compared (CLEAR_OUT's 0xCC fill would catch a short write anyway).
X_ARP_REQUEST	DB 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x08,0x06
		DB 0x00,0x01,0x08,0x00,0x06,0x04,0x00,0x01
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 192,168,7,21
		DB 0x00,0x00,0x00,0x00,0x00,0x00
		DB 192,168,7,44

; The peer PING and ARP resolve to: 192.168.7.44 at 00:11:22:33:44:55.
X_IP_PEER	DB 192,168,7,44
X_IP_OTHER	DB 192,168,7,99
X_PEER_MAC	DB 0x00,0x11,0x22,0x33,0x44,0x55

; Echo request as PING_BUILD_ECHO must lay it out: peer MAC, station MAC,
; IPv4 EtherType, then a 20-byte header for a 28-byte datagram carrying the
; identifier from S9_IP_ID. Both checksums are left out of the comparison
; and validated by summing the built bytes instead.
X_PING_HEAD	DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x08,0x00
		DB 0x45,0x00,0x00,0x1C,0x12,0x34,0x40,0x00,64,0x01
X_PING_ADDRS	DB 192,168,7,21		; source: this station
		DB 192,168,7,44		; destination: the peer
X_PING_ICMP	DB 8,0			; echo request, code 0
X_PING_SEQ	DB 0,1

; The matching echo reply, checksums computed for exactly these bytes.
X_ECHO_REPLY	DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x08,0x00
		DB 0x45,0x00,0x00,0x1C,0x12,0x34,0x40,0x00,64,0x01
		DB 0x99,0x1B
		DB 192,168,7,44
		DB 192,168,7,21
		DB 0x00,0x00,0x3A,0x57,0xC5,0xA7,0x00,0x01

; The same reply, but carried to a different station: IPV4.PARSE rejects it
; on IP4P_EXPECT_DESTINATION, which PING_PARSE_REPLY fills from CCTX_LOCAL_IP.
X_ECHO_NOT_OURS	DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x08,0x00
		DB 0x45,0x00,0x00,0x1C,0x12,0x34,0x40,0x00,64,0x01
		DB 0x98,0xCD
		DB 192,168,7,44
		DB 192,168,7,99
		DB 0x00,0x00,0x3A,0x57,0xC5,0xA7,0x00,0x01

; ARP reply from the peer we asked about, unicast to this station.
X_ARP_REPLY	DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x08,0x06
		DB 0x00,0x01,0x08,0x00,0x06,0x04,0x00,0x02
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 192,168,7,44
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 192,168,7,21

; Same reply, but the sender is not the address the route is waiting for.
X_ARP_REPLY_OTHER
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x08,0x06
		DB 0x00,0x01,0x08,0x00,0x06,0x04,0x00,0x02
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 192,168,7,99
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 192,168,7,21

; Broadcast ARP request asking for this station's address.
X_ARP_REQUEST_IN
		DB 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x08,0x06
		DB 0x00,0x01,0x08,0x00,0x06,0x04,0x00,0x01
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 192,168,7,44
		DB 0x00,0x00,0x00,0x00,0x00,0x00
		DB 192,168,7,21

; The reply ARP_BUILD_REPLY must produce for it.
X_ARP_REPLY_OUT	DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 0x08,0x06
		DB 0x00,0x01,0x08,0x00,0x06,0x04,0x00,0x02
		DB 0x00,0x20,0xAF,0x12,0x34,0x56
		DB 192,168,7,21
		DB 0x00,0x11,0x22,0x33,0x44,0x55
		DB 192,168,7,44

; One UNET_UDP_CTX slot: remote IP, remote MAC, remote port 8080, local
; port 0xC401 (the shim's own default for channel 1).
X_DNS_NAME	DB "ns.test",0
X_DNS_NAME_LONG	DB "a.longer.example.test",0
X_DNS_EMPTY	DB 0
X_IP_ANSWER	DB 192,168,7,77

; The query CFN_DNS_BUILD_FRAME must produce for X_DNS_NAME with
; transaction id 0xBEEF, IP identifier 0x1234 (written back incremented),
; X_IP_HOST -> X_IP_PEER, X_MAC -> X_PEER_MAC.
X_DNS_FRAME
	DB	0x00,0x11,0x22,0x33,0x44,0x55,0x00,0x20,0xAF,0x12,0x34,0x56
	DB	0x08,0x00,0x45,0x00,0x00,0x35,0x12,0x35,0x40,0x00,0x40,0x11
	DB	0x98,0xF1,0xC0,0xA8,0x07,0x15,0xC0,0xA8,0x07,0x2C,0xD0,0x35
	DB	0x00,0x35,0x00,0x21,0x00,0x00,0xBE,0xEF,0x01,0x00,0x00,0x01
	DB	0x00,0x00,0x00,0x00,0x00,0x00,0x02,0x6E,0x73,0x04,0x74,0x65
	DB	0x73,0x74,0x00,0x00,0x01,0x00,0x01

; The matching reply: one A record for X_DNS_NAME, its owner name written
; as a compression pointer back to the question.
X_DNS_PAYLOAD
	DB	0xBE,0xEF,0x81,0x80,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00
	DB	0x02,0x6E,0x73,0x04,0x74,0x65,0x73,0x74,0x00,0x00,0x01,0x00
	DB	0x01,0xC0,0x0C,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x3C,0x00
	DB	0x04,0xC0,0xA8,0x07,0x4D

X_DNS_REPLY_FRAME
	DB	0x00,0x20,0xAF,0x12,0x34,0x56,0x00,0x11,0x22,0x33,0x44,0x55
	DB	0x08,0x00,0x45,0x00,0x00,0x45,0x43,0x21,0x40,0x00,0x40,0x11
	DB	0x67,0xF5,0xC0,0xA8,0x07,0x2C,0xC0,0xA8,0x07,0x15,0x00,0x35
	DB	0xD0,0x35,0x00,0x31,0x00,0x00,0xBE,0xEF,0x81,0x80,0x00,0x01
	DB	0x00,0x01,0x00,0x00,0x00,0x00,0x02,0x6E,0x73,0x04,0x74,0x65
	DB	0x73,0x74,0x00,0x00,0x01,0x00,0x01,0xC0,0x0C,0x00,0x01,0x00
	DB	0x01,0x00,0x00,0x00,0x3C,0x00,0x04,0xC0,0xA8,0x07,0x4D

X_UDP_SLOT1	DB 10,0,0,7
		DB 0xAA,0xBB,0xCC,0xDD,0xEE,0xFF
		DW 0x1F90
		DW 0xC401

X_TCP_ODD
	DB 0x00,0x20,0xAF,0x12,0x34,0x56,0x00,0x11,0x22,0x33,0x44,0x55,0x08,0x00
	DB 0x45,0x00,0x00,0x2B,0x51,0x11,0x40,0x00,0x3E,0x06,0x5C,0x2A
	DB 192,168,7,44,192,168,7,21
	DB 0x00,0x50,0xD0,0x58,0x10,0x21,0x30,0x41,0x02,0x03,0x04,0x05
	DB 0x50,0x18,0x10,0x00,0x74,0xE2,0x00,0x00
X_TCP_PAYLOAD_ODD
	DB 'A','B','C',0,0,0
X_TCP_SEQUENCE	DB 0x10,0x21,0x30,0x41
X_TCP_ACK	DB 0x02,0x03,0x04,0x05
X_TCP_NEXT_ODD	DB 0x10,0x21,0x30,0x44

X_TCP_EVEN
	DB 0x00,0x20,0xAF,0x12,0x34,0x56,0x00,0x11,0x22,0x33,0x44,0x55,0x08,0x00
	DB 0x45,0x00,0x00,0x2C,0x51,0x11,0x40,0x00,0x3E,0x06,0x5C,0x29
	DB 192,168,7,44,192,168,7,21
	DB 0x00,0x50,0xD0,0x58,0x10,0x21,0x30,0x41,0x02,0x03,0x04,0x05
	DB 0x50,0x18,0x10,0x00,0x74,0x9D,0x00,0x00
X_TCP_PAYLOAD_EVEN
	DB 'A','B','C','D',0,0
X_TCP_NEXT_EVEN DB 0x10,0x21,0x30,0x45

X_TCP_ACK_ONLY
	DB 0x00,0x20,0xAF,0x12,0x34,0x56,0x00,0x11,0x22,0x33,0x44,0x55,0x08,0x00
	DB 0x45,0x00,0x00,0x28,0x51,0x11,0x40,0x00,0x3E,0x06,0x5C,0x2D
	DB 192,168,7,44,192,168,7,21
	DB 0x00,0x50,0xD0,0x58,0x10,0x21,0x30,0x41,0x02,0x03,0x04,0x05
	DB 0x50,0x10,0x10,0x00,0xF9,0x2F,0x00,0x00,0,0,0,0,0,0

	SAVEBIN "cold_vectors.bin",0,0x10000
