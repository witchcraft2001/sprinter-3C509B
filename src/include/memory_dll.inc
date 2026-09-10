; Relocatable BSS layout for UNET_DLL (src/dll/unet509b.asm).
;
; memory.inc's normal body computes every address from RUNTIME_BASE (0xB000)
; and PAGE_BASE (a caller-owned mapped DSS page) -- both are fixed physical
; addresses in the consumer's own address space and would collide with
; whatever the DLL's host program keeps there. A libman DLL instead carries
; all of its state as `DS n,0` INSIDE its own relocatable image (see
; unet509b.asm's header comment), so every address here is DLL_BSS + a
; literal offset instead.
;
; This file assumes unet509b.asm has ALREADY defined, before including
; "memory.inc" (which IFDEFs UNET_DLL straight into this file): every
; BSS_* region offset, DLL_BSS itself (the `DS DLL_BSS_SIZE,0` reservation)
; and RUNTIME_BASE EQU DLL_BSS + BSS_RT. This file only adds the SAME
; symbol names the shared libraries already expect from memory.inc,
; pointed at those literal offsets -- nothing here consumes image space.
;
; Populated incrementally as each phase links in the library it needs
; (see the plan's P1..P5 gates); P1 only needs the BSS_UNET scalar layout
; the shim's own INIT/GETCAPS/STATUS/GETINFO/SETOPT/LASTERR bodies touch.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_MEMORY_DLL_INC
	DEFINE	_MEMORY_DLL_INC

; ------------------------------------------------------
; BSS_UNET: shim-private dispatcher scalars (see unet509b.asm's BSS_UNET
; region, 112 bytes). Field layout here, offsets from BSS_UNET's own base.
; ------------------------------------------------------
UNET_WIN_BASE		EQU DLL_BSS + BSS_UNET + 0x00	; word, this image's own page (WIN1/WIN2), from INIT
UNET_INITED		EQU DLL_BSS + BSS_UNET + 0x02	; NETINIT has completed successfully
UNET_CH_STATE		EQU DLL_BSS + BSS_UNET + 0x03	; 2 bytes, one per channel: 0 closed/1 open/2 udp/3 listening
UNET_ARG_A		EQU DLL_BSS + BSS_UNET + 0x05
UNET_ARG_DE		EQU DLL_BSS + BSS_UNET + 0x06	; word
UNET_ARG_IX		EQU DLL_BSS + BSS_UNET + 0x08	; word
UNET_ARG_IY		EQU DLL_BSS + BSS_UNET + 0x0A	; word
UNET_STAGE		EQU DLL_BSS + BSS_UNET + 0x0C	; LASTERR "st=" mnemonic/code
UNET_LAST_NERR		EQU DLL_BSS + BSS_UNET + 0x0D
UNET_TCP_LAST		EQU DLL_BSS + BSS_UNET + 0x0E	; raw TCP_ERR_*/EL3_ERR_* before NERR_* mapping
UNET_DIAG_EL3		EQU DLL_BSS + BSS_UNET + 0x0F	; 3 bytes: EL3_LAST_STAGE + EL3_LAST_STATUS (word)
UNET_OPT_SLICE		EQU DLL_BSS + BSS_UNET + 0x12	; word, UNET_OPT_SENDSLICE ms (0 = blocking)
UNET_APEND_ACTIVE	EQU DLL_BSS + BSS_UNET + 0x14	; a SEND is suspended with NERR_AGAIN
UNET_APEND_CHANNEL	EQU DLL_BSS + BSS_UNET + 0x15
UNET_APEND_DE		EQU DLL_BSS + BSS_UNET + 0x16	; word, resume contract: same buffer
UNET_APEND_IX		EQU DLL_BSS + BSS_UNET + 0x18	; word, resume contract: same length
UNET_LISTEN_CHANNEL	EQU DLL_BSS + BSS_UNET + 0x1A
UNET_LISTEN_PORT	EQU DLL_BSS + BSS_UNET + 0x1B	; word, host order
UNET_LISTEN_ACCEPTED	EQU DLL_BSS + BSS_UNET + 0x1D
UNET_CANCEL_MODE	EQU DLL_BSS + BSS_UNET + 0x1E	; SETOPT CANCELKEYS
UNET_CANCELLED		EQU DLL_BSS + BSS_UNET + 0x1F
UNET_TICKS16		EQU DLL_BSS + BSS_UNET + 0x20	; word, NETTIME.TICK counter (cancel-poll cadence)
UNET_UDP_CTX		EQU DLL_BSS + BSS_UNET + 0x22	; 2 * 14 bytes, connected-UDP per-channel context
UNET_UDP_CTX_SIZE	EQU 14
; Field layout within one UNET_UDP_CTX[channel] slot (offsets, not addresses
; -- add to UNET_UDP_CTX + channel*UNET_UDP_CTX_SIZE).
UDPCTX_REMOTE_IP	EQU 0	; four bytes
UDPCTX_REMOTE_MAC	EQU 4	; six bytes
UDPCTX_REMOTE_PORT	EQU 10	; word, host order
UDPCTX_LOCAL_PORT	EQU 12	; word, host order
	ASSERT UDPCTX_LOCAL_PORT + 2 == UNET_UDP_CTX_SIZE
UNET_COLD_CTX		EQU DLL_BSS + BSS_UNET + 0x36	; CCTX_SIZE (46)
UNET_SAVE_SP		EQU DLL_BSS + BSS_UNET + 0x64	; word, COLD.RUN's private-stack switch
UNET_CONNECT_IP		EQU DLL_BSS + BSS_UNET + 0x66	; four bytes, F_CONNECT/F_UDPOPEN/F_RESOLVE/F_PING's parsed target IP scratch
UNET_UDP_RPORT		EQU DLL_BSS + BSS_UNET + 0x6A	; word, F_UDPOPEN's parsed remote port scratch
UNET_UDP_LPORT		EQU DLL_BSS + BSS_UNET + 0x6C	; word, F_UDPOPEN's parsed local port scratch
UNET_BSS_USED		EQU 0x6E
	ASSERT UNET_COLD_CTX + CCTX_SIZE <= DLL_BSS + BSS_UNET + 0x70	; BSS_UNET size, see unet509b.asm
	ASSERT UNET_BSS_USED <= 0x70

; ------------------------------------------------------
; BSS_RT: the driver stack's own resident scalars (el3*/netdrv/arp/nettime/
; stage9_app), packed tightly instead of mirroring memory.inc's sparse
; RUNTIME_BASE+0x.. layout -- nothing outside this file computes an offset
; into this block, so only literal presence (not memory.inc's spacing)
; matters. Added incrementally as each linked library's own undefined-symbol
; errors demanded a field; see unet509b.asm's own INCLUDE chain comment.
; unet509b.asm defines RUNTIME_BASE EQU DLL_BSS+BSS_RT before including
; memory.inc (which IFDEFs UNET_DLL straight into this file), and also
; predefines S9_ENV_BUFFER itself (aliased onto DLL_BSS+BSS_RX, since RX is
; idle while NETINIT reads the environment) -- not repeated here.
; ------------------------------------------------------

; el3.asm / el3_io.asm / el3_fifo.asm / el3_regs.asm / el3_algorithms.asm
EL3_IDPORT		EQU RUNTIME_BASE + 0x00	; word
EL3_BASE		EQU RUNTIME_BASE + 0x02	; word
EL3_LAST_STAGE		EQU RUNTIME_BASE + 0x04
EL3_LAST_TICKS		EQU RUNTIME_BASE + 0x05	; word
EL3_LAST_STATUS		EQU RUNTIME_BASE + 0x07	; word
EL3_MAC			EQU RUNTIME_BASE + 0x09	; six bytes
EL3_LAST_COMMAND	EQU RUNTIME_BASE + 0x0F	; word
EL3_EXPECT_MEDIA	EQU RUNTIME_BASE + 0x11	; word
EL3_COUNT_RESET		EQU RUNTIME_BASE + 0x13	; word
EL3_COUNT_TIMEOUT	EQU RUNTIME_BASE + 0x15	; word
EL3_COUNT_RX		EQU RUNTIME_BASE + 0x17	; word
EL3_COUNT_TX		EQU RUNTIME_BASE + 0x19	; word
EL3_COUNT_DROP		EQU RUNTIME_BASE + 0x1B	; word
EL3_COUNT_FRAME		EQU RUNTIME_BASE + 0x1D	; word
EL3_VERIFY_FIELD	EQU RUNTIME_BASE + 0x1F
EL3_VERIFY_EXPECTED	EQU RUNTIME_BASE + 0x20	; word
EL3_VERIFY_ACTUAL	EQU RUNTIME_BASE + 0x22	; word
EL3_LAST_RX_STATUS	EQU RUNTIME_BASE + 0x24	; word
EL3_LAST_TX_STATUS	EQU RUNTIME_BASE + 0x26
EL3_RX_REQUIRED		EQU RUNTIME_BASE + 0x27	; word
; EEPROM_BUFFER aliases the idle RX buffer, like S9_ENV_BUFFER above: both
; are only touched during NETINIT, before any frame has been received.
EEPROM_BUFFER		EQU DLL_BSS + BSS_RX		; 128 bytes

; netdrv.asm
NETDRV_CONFIG		EQU RUNTIME_BASE + 0x29	; NETDRV_CONFIG_LENGTH (15) bytes
NETDRV_ACTIVE		EQU RUNTIME_BASE + 0x38
NETDRV_MEMORY_BLOCK	EQU RUNTIME_BASE + 0x39
NETDRV_PAGE_ALLOCATED	EQU RUNTIME_BASE + 0x3A
NETDRV_FAIL_CODE	EQU RUNTIME_BASE + 0x3B
NETDRV_SAVED_IX		EQU RUNTIME_BASE + 0x3C	; word
NETDRV_BUFFER_PTR	EQU RUNTIME_BASE + 0x3E	; word
NETDRV_BUFFER_LEN	EQU RUNTIME_BASE + 0x40	; word
NETDRV_STATION_MAC	EQU RUNTIME_BASE + 0x42	; six bytes
NETDRV_SELECTED_SLOT	EQU RUNTIME_BASE + 0x48
NETDRV_SELECTED_BASE	EQU RUNTIME_BASE + 0x49	; word

; arp.asm (SELECT_NEXT_HOP, hot) / netdrv.asm config / tcp_transport.asm route
NET_LOCAL_IP		EQU RUNTIME_BASE + 0x4B	; four bytes
NET_NETMASK		EQU RUNTIME_BASE + 0x4F	; four bytes
NET_GATEWAY		EQU RUNTIME_BASE + 0x53	; four bytes
NET_TARGET_IP		EQU RUNTIME_BASE + 0x57	; four bytes
NET_NEXT_HOP_IP		EQU RUNTIME_BASE + 0x5B	; four bytes
NET_RESULT_MAC		EQU RUNTIME_BASE + 0x5F	; six bytes
NET_DNS1		EQU RUNTIME_BASE + 0x65	; four bytes
NET_DNS2		EQU RUNTIME_BASE + 0x69	; four bytes

; nettime.asm (STAGE12_LAYOUT branch: fixed 21 MHz base + coarse wall backstop;
; NETTIME_QPS/CAL_COUNT/ACC_LO/ACC_HI belong only to the non-STAGE12 per-ms
; calibration loop, which unet509b.asm's DEFINE set never takes)
NETTIME_TIMEOUT_MS	EQU RUNTIME_BASE + 0x6D	; word
NETTIME_QUANTA_LEFT	EQU RUNTIME_BASE + 0x6F	; word
NETTIME_QUANTA_TOTAL	EQU RUNTIME_BASE + 0x71	; word
NETTIME_ELAPSED_MS	EQU RUNTIME_BASE + 0x73	; word
NETTIME_MS_PER_QUANTUM	EQU RUNTIME_BASE + 0x75	; word
NETTIME_WALL_LIMIT	EQU RUNTIME_BASE + 0x77	; word
NETTIME_START_WALL	EQU RUNTIME_BASE + 0x79	; word
NETTIME_CAL_SECOND	EQU RUNTIME_BASE + 0x7B

; stage9_app.asm's LOAD_ACTIVE_CONFIG (NETINIT env parsing, kept hot -- see
; the plan's env-parsing reuse decision)
S9_FLAGS		EQU RUNTIME_BASE + 0x7C
S9_PRIMARY_ERROR	EQU RUNTIME_BASE + 0x7D
S9_RX_LENGTH		EQU RUNTIME_BASE + 0x7E	; word
S9_TFTP_FILE_HANDLE	EQU RUNTIME_BASE + 0x80
S9_TFTP_FILE_OPEN	EQU RUNTIME_BASE + 0x81

; udp_transport.asm (MODULE UDPX): connected-UDP tuple scalars, swapped in
; from UNET_UDP_CTX[channel] by the shim's SELECT_UDP_CONTEXT before every
; SEND/WAIT (the module itself only ever tracks one tuple at a time -- see
; unet509b.asm's own header comment on F_UDPOPEN/F_SEND/F_RECV). ANSWER_ECHO
; and its S9_ICMP_COPY_DESC/S9_INCOMING_IP are IFNDEF UNET_DLL in
; udp_transport.asm itself and never reach here.
S9_LOCAL_PORT		EQU RUNTIME_BASE + 0x82	; word
S9_REMOTE_PORT		EQU RUNTIME_BASE + 0x84	; word
S9_EXPECT_REMOTE_PORT	EQU RUNTIME_BASE + 0x86	; word
S9_IP_ID		EQU RUNTIME_BASE + 0x88	; word
S9_RX_PAYLOAD		EQU RUNTIME_BASE + 0x8A	; word
S9_RX_PAYLOAD_LENGTH	EQU RUNTIME_BASE + 0x8C	; word
S9_RX_SOURCE_PORT	EQU RUNTIME_BASE + 0x8E	; word
S9_REPLY_TTL		EQU RUNTIME_BASE + 0x90
S9_DRAIN_LEFT		EQU RUNTIME_BASE + 0x91
S9_UDP_BUILD_DESC	EQU RUNTIME_BASE + 0x92	; UDPB_DESC_LENGTH = 14 bytes
S9_UDP_PARSE_DESC	EQU RUNTIME_BASE + 0xA0	; UDPP_DESC_LENGTH = 20 bytes
S9_IPV4_BUILD_DESC	EQU RUNTIME_BASE + 0xB4	; IP4B_LENGTH = 14 bytes
S9_IPV4_PARSE_DESC	EQU RUNTIME_BASE + 0xC2	; IP4P_DESC_LENGTH = 18 bytes

; unet509b.asm's own F_PING poll loop (a hand-written replacement for the
; standalone ping.asm app, not linked into this DLL): one ICMP Echo build
; and one expected-reply descriptor, reused across every wait iteration.
PING_ICMP_BUILD_DESC	EQU RUNTIME_BASE + 0xD4	; ICMPB_LENGTH = 11 bytes
PING_ICMP_REPLY_DESC	EQU RUNTIME_BASE + 0xDF	; ICMPR_LENGTH = 10 bytes

; stage12_dns.asm (MODULE DNSX): RESOLVE_OR_LITERAL's own scratch. BUILD_QUERY
; and PARSE_DNS_REPLY move to the cold blob for UNET_DLL (see coldctx.inc's
; CCTX_DNS_* pointers); these cells stay hot since GENERATE_ID needs DSS_SYSTIME
; (forbidden in cold code) and RESOLVE_OR_LITERAL itself drives the NETDRV/
; NETTIME polling loop, which is hot everywhere else too.
DNS_NAME_POINTER	EQU RUNTIME_BASE + 0xE9	; word
DNS_TRANSACTION_ID	EQU RUNTIME_BASE + 0xEB	; word
DNS_SERVER_INDEX	EQU RUNTIME_BASE + 0xED
DNS_ATTEMPTS		EQU RUNTIME_BASE + 0xEE
DNS_LAST_ERROR		EQU RUNTIME_BASE + 0xEF
DNS_RESULT_IP		EQU RUNTIME_BASE + 0xF0	; four bytes

BSS_RT_USED		EQU 0xF4
	ASSERT BSS_RT_USED <= BSS_UNET - BSS_RT		; stays inside the BSS_RT region

; ------------------------------------------------------
; tcp_transport.asm (MODULE TCPX): STAGE9_TX/RX_BUFFER point at the DLL's
; own packet buffers (BSS_TX/BSS_RX, unet509b_bss.inc) instead of a mapped
; DSS page; S11_* is the verbatim 0x00..0x9F relative layout memory.inc uses
; for the two-context (non-STAGE13-string, non-STAGE12-single-context)
; case, since the DLL keeps two real TCP contexts (BSS_CTX0/BSS_CTX1) and
; two real one-MSS pending queues (BSS_PEND0/BSS_PEND1, plan decision #2).
; ------------------------------------------------------
STAGE9_TX_BUFFER	EQU DLL_BSS + BSS_TX	; ARP request/reply only now, see unet509b_bss.inc
STAGE9_TX_CAPACITY	EQU 60
STAGE9_RX_BUFFER	EQU DLL_BSS + BSS_RX
STAGE9_RX_CAPACITY	EQU 1514

S11_CONTEXT_SIZE	EQU 40
S11_PENDING0		EQU DLL_BSS + BSS_PEND0
S11_PENDING1		EQU DLL_BSS + BSS_PEND1
S11_PENDING_CAPACITY	EQU 536
S11_CONTEXT0		EQU DLL_BSS + BSS_CTX0
S11_CONTEXT1		EQU DLL_BSS + BSS_CTX1
S11_CONTEXT_SCRATCH	EQU DLL_BSS + BSS_CTX_SCRATCH	; plan decision #7 (DNS/PING/UDPOPEN route)
S11_STATE_BASE		EQU DLL_BSS + BSS_S11

S11_TCP_BUILD_DESC	EQU S11_STATE_BASE + 0x00
S11_BURST_SEQ		EQU S11_STATE_BASE + 0x17	; four bytes, network order (TCPX_SEND_BURST only)
S11_BURST_FIRST		EQU S11_STATE_BASE + 0x1B	; word
S11_BURST_PAIR		EQU S11_STATE_BASE + 0x1D
S11_TCP_PARSE_DESC	EQU S11_STATE_BASE + 0x20
S11_PARSE_SEQUENCE	EQU S11_STATE_BASE + 0x40
S11_PARSE_ACK		EQU S11_STATE_BASE + 0x44
S11_SELECTED_CONTEXT	EQU S11_STATE_BASE + 0x48	; word
S11_MATCH_CONTEXT	EQU S11_STATE_BASE + 0x4A	; word
S11_SEND_POINTER	EQU S11_STATE_BASE + 0x4C	; word
S11_SEND_REMAINING	EQU S11_STATE_BASE + 0x4E	; word
S11_SEND_CONFIRMED	EQU S11_STATE_BASE + 0x50	; word
S11_SEGMENT_LENGTH	EQU S11_STATE_BASE + 0x52	; word
S11_TARGET_ACK		EQU S11_STATE_BASE + 0x54	; four bytes, network order
S11_FRAME_LENGTH	EQU S11_STATE_BASE + 0x58	; word
S11_TCP_LENGTH		EQU S11_STATE_BASE + 0x5A	; word
S11_IP_ID		EQU S11_STATE_BASE + 0x5C	; word
S11_SEGMENT_ACCEPTED	EQU S11_STATE_BASE + 0x5F
S11_CHANNEL		EQU S11_STATE_BASE + 0x60
S11_COPY_LENGTH		EQU S11_STATE_BASE + 0x61	; word
S11_BUILD_FLAGS		EQU S11_STATE_BASE + 0x63
S11_WAIT_MASK		EQU S11_STATE_BASE + 0x64
S11_ACTIVE_LENGTH	EQU S11_STATE_BASE + 0x65	; word
S11_TIMEOUT_MS		EQU S11_STATE_BASE + 0x67	; word
S11_DIAG_STAGE		EQU S11_STATE_BASE + 0x69
S11_SEQUENCE_OVERRIDE	EQU S11_STATE_BASE + 0x6A
S11_NEXT_LOCAL_PORT	EQU S11_STATE_BASE + 0x6B	; word, 49152..65535
S11_WAIT_ALL		EQU S11_STATE_BASE + 0x6D
S11_ACK_NOW		EQU S11_STATE_BASE + 0x6E
S11_ACK_OWED		EQU S11_STATE_BASE + 0x6F
S11_IPV4_BUILD_DESC	EQU S11_STATE_BASE + 0x70
S11_IPV4_PARSE_DESC	EQU S11_STATE_BASE + 0x80	; IP4P_DESC_LENGTH = 18 bytes
S11_FAST_LENGTH		EQU S11_STATE_BASE + 0x92	; word
S11_FAST_BADSUM		EQU S11_STATE_BASE + 0x94	; word
S11_RX_DEST		EQU S11_STATE_BASE + 0x96	; word
S11_RX_FREE		EQU S11_STATE_BASE + 0x98	; word
S11_RX_DELIVERED	EQU S11_STATE_BASE + 0x9A	; word
S11_FAST_DEST		EQU S11_STATE_BASE + 0x9C	; word
S11_FAST_DIRECT		EQU S11_STATE_BASE + 0x9E
S11_WAIT_PROGRESS	EQU S11_STATE_BASE + 0x9F
; TCPX_ASYNCSEND (P5): the remaining ms budget within the CURRENT retry
; attempt of SEND's own .DATA_WAIT, sliced across suspend/resume (the
; window-probe wait is never sliced -- see tcp_transport.asm's own
; comment on WAIT_REMOTE_WINDOW -- so no phase flag is needed: a resume
; always re-enters .DATA_WAIT).
S11_ASYNC_MS_LEFT	EQU S11_STATE_BASE + 0xA0	; word
	ASSERT S11_ASYNC_MS_LEFT + 2 <= S11_STATE_BASE + 0xA2	; == BSS_S11 size, see unet509b_bss.inc

	ENDIF
