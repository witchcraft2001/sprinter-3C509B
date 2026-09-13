; coldctx.inc -- shared field layout for the WIN0-cold-code parameter block,
; agreed between src/dll/unet509b.asm (which builds the block once, in its
; own BSS, and passes its address in IX to COLD.RUN) and
; src/dll/unet509b_cold.asm (which reads it via +offset from IX -- the cold
; blob never touches an absolute address of the main DLL image directly,
; only via pointers handed to it in this block or in registers at call
; time, since the two are assembled and relocated independently).
;
; Literal offsets only, never a computed difference of two addresses (see
; the plan's relocation rule): every field the DLL fills in is an ordinary
; "LD HL,label" against its own BSS, relocatable like any other reference.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_COLDCTX_INC
	DEFINE	_COLDCTX_INC

; ---- offsets within the COLD_CTX block itself (all DW pointers) ----
; The combined TCP/IP builder consumes CCTX_TX_BUF. Route selection stays hot,
; so the old netmask/gateway placeholders are omitted entirely rather than
; spending four resident bytes on pointers the cold blob never dereferences.
; TCPX_TX_BUFFER deliberately aliases STAGE9_RX_BUFFER in the DLL, so the
; same pointer serves both cold RX predicates and the combined ACK builder.
CCTX_TX_BUF		EQU 0	; &STAGE9_RX_BUFFER / TCPX_TX_BUFFER
CCTX_RX_BUF		EQU CCTX_TX_BUF
CCTX_LOCAL_IP		EQU 2	; &NET_LOCAL_IP (4 bytes)
CCTX_STATION_MAC	EQU 4	; &NETDRV_STATION_MAC (6 bytes)
CCTX_TARGET_IP		EQU 6	; &NET_TARGET_IP (4 bytes)
CCTX_NEXT_HOP_IP	EQU 8	; &NET_NEXT_HOP_IP (4 bytes)
CCTX_RESULT_MAC		EQU 10	; &NET_RESULT_MAC (6 bytes)
CCTX_IP_ID		EQU 12	; &S9_IP_ID (word, host order)
CCTX_DNS_XID		EQU 14	; &DNS_TRANSACTION_ID (word)
CCTX_DNS_RESULT		EQU 16	; &DNS_RESULT_IP (4 bytes)
CCTX_DNS_PAYLOAD_END	EQU 18	; &S9_RX_PAYLOAD (word, PARSE_DNS_REPLY scratch)
CCTX_DNS_DRAIN		EQU 20	; &S9_DRAIN_LEFT (byte, PARSE_DNS_REPLY scratch)
CCTX_DNS_IP_BUILD_DESC	EQU 22	; &S9_IPV4_BUILD_DESC (BUILD_FRAME scratch)
CCTX_DNS_IP_PARSE_DESC	EQU 24	; &S9_IPV4_PARSE_DESC (PARSE_REPLY_FRAME scratch)
CCTX_DNS_NAME_PTR	EQU 26	; &DNS_NAME_POINTER (word, double indirection)
CCTX_DNS_FRAME_LEN	EQU 28	; &S9_RX_LENGTH (word, BUILD_FRAME's own output)
CCTX_DNS_RX_LEN		EQU 30	; &S11_FRAME_LENGTH (word, PARSE_REPLY_FRAME's input)
CCTX_PING_BUILD_DESC	EQU 32	; &PING_ICMP_BUILD_DESC (F_PING's own echo-request scratch)
CCTX_PING_REPLY_DESC	EQU 34	; &PING_ICMP_REPLY_DESC (F_PING's own echo-reply scratch)
CCTX_UDP_CTX_BASE	EQU 36	; &UNET_UDP_CTX (2 * UNET_UDP_CTX_SIZE bytes)
CCTX_S9_LOCAL_PORT	EQU 38	; &S9_LOCAL_PORT (word; +2/+4 reach REMOTE_PORT/EXPECT_REMOTE_PORT)
CCTX_TCP_STATE_BASE	EQU 40	; &S11_STATE_BASE; cold uses shared literal offsets
CCTX_TCP_PENDING0	EQU 42	; &S11_PENDING0 (PENDING1 follows by TCP_MSS)
CCTX_TCP_CONTEXT0	EQU 44	; &S11_CONTEXT0 (CONTEXT1 follows by 40)
CCTX_EL3_RXS_SUM	EQU 46	; &EL3IO.RXS_SUM
CCTX_CB_RX_PAYLOAD	EQU 48	; hot RX_PAYLOAD entry address
CCTX_CB_RX_PAYLOAD_SUM	EQU 50	; hot RX_PAYLOAD_SUM entry address
CCTX_SIZE		EQU 52

; ---- cold dispatch function codes (A on COLD.RUN entry) ----
CFN_IPV4_BUILD		EQU 0
CFN_IPV4_PARSE		EQU 1
CFN_TCP_BUILD		EQU 2
CFN_TCP_PARSE		EQU 3
CFN_UDP_BUILD		EQU 4
CFN_UDP_PARSE		EQU 5
CFN_ICMP_BUILD_ECHO	EQU 6
CFN_ICMP_PARSE_REPLY	EQU 7
CFN_ARP_BUILD_REQUEST	EQU 8
CFN_ARP_BUILD_REPLY	EQU 9
CFN_ARP_PARSE		EQU 10
CFN_DNS_BUILD_QUERY	EQU 11
CFN_DNS_PARSE_REPLY	EQU 12
CFN_PARSE_IPV4		EQU 13
CFN_PARSE_MAC		EQU 14
CFN_PARSE_HW		EQU 15
CFN_PARSE_U16		EQU 16
; slot 17 was CFN_UDP_UNREACH, dropped by F2; reused for the DNS reply's UDP
; checksum (ethernet.asm's own copy lives only in the cold blob for UNET_DLL)
CFN_ETH_UDP_CHECKSUM	EQU 17
CFN_FORMAT_IPV4		EQU 18	; F_RESOLVE's binary-IP-to-text formatter
CFN_DNS_BUILD_FRAME	EQU 19
CFN_DNS_PARSE_FRAME	EQU 20
CFN_DNS_VALIDATE_NAME	EQU 21
CFN_PING_BUILD_ECHO	EQU 22
CFN_PING_PARSE_REPLY	EQU 23
CFN_PARSE_PORT		EQU 24
; COPY_LIMITED is deliberately NOT a cold function: GETINFO/LASTERR must
; work before NETINIT and after a failed one (see unet509b.asm).
CFN_UDP_CTX_PTR		EQU 25
CFN_SELECT_UDP_CONTEXT	EQU 26
CFN_DNS_NONZERO_IP	EQU 27
CFN_DNS_COPY_RESULT	EQU 28
CFN_MAP_RECV_FAIL	EQU 29
CFN_MAP_CONNECT_FAIL	EQU 30
CFN_TCP_FAST_RECEIVE	EQU 31
CFN_EL3_BASE_ENCODE	EQU 32
CFN_EL3_VALIDATE	EQU 33
CFN_TCP_IP_BUILD	EQU 34
CFN_MAP_SEND_FAIL	EQU 35
CFN_MAP_DNS_FAIL	EQU 36
CFN_TCP_SEND_EVENT	EQU 37
CFN_COUNT		EQU 38

	ENDIF
