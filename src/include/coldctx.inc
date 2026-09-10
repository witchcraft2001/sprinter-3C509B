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
; Three offsets are reserved rather than live: ARP building takes its output
; buffer in DE, and route selection stayed hot, so the blob dereferences
; neither CCTX_TX_BUF nor the netmask/gateway pair. FILL_COLD_CTX therefore
; does not fill them -- 18 bytes of an image with no headroom. Give one a
; cold use and check-stage14.pl will require the matching store.
CCTX_TX_BUF		EQU 0	; reserved; &TX buffer (STAGE9_TX_BUFFER)
CCTX_RX_BUF		EQU 2	; &RX buffer (STAGE9_RX_BUFFER)
CCTX_LOCAL_IP		EQU 4	; &NET_LOCAL_IP (4 bytes)
CCTX_STATION_MAC	EQU 6	; &NETDRV_STATION_MAC (6 bytes)
CCTX_TARGET_IP		EQU 8	; &NET_TARGET_IP (4 bytes)
CCTX_NEXT_HOP_IP	EQU 10	; &NET_NEXT_HOP_IP (4 bytes)
CCTX_RESULT_MAC		EQU 12	; &NET_RESULT_MAC (6 bytes)
CCTX_NETMASK		EQU 14	; reserved; &NET_NETMASK (4 bytes)
CCTX_GATEWAY		EQU 16	; reserved; &NET_GATEWAY (4 bytes)
CCTX_IP_ID		EQU 18	; &S9_IP_ID (word, host order)
CCTX_DNS_XID		EQU 20	; &DNS_TRANSACTION_ID (word)
CCTX_DNS_RESULT		EQU 22	; &DNS_RESULT_IP (4 bytes)
CCTX_DNS_PAYLOAD_END	EQU 24	; &S9_RX_PAYLOAD (word, PARSE_DNS_REPLY scratch)
CCTX_DNS_DRAIN		EQU 26	; &S9_DRAIN_LEFT (byte, PARSE_DNS_REPLY scratch)
CCTX_DNS_IP_BUILD_DESC	EQU 28	; &S9_IPV4_BUILD_DESC (BUILD_FRAME scratch)
CCTX_DNS_IP_PARSE_DESC	EQU 30	; &S9_IPV4_PARSE_DESC (PARSE_REPLY_FRAME scratch)
CCTX_DNS_NAME_PTR	EQU 32	; &DNS_NAME_POINTER (word, double indirection)
CCTX_DNS_FRAME_LEN	EQU 34	; &S9_RX_LENGTH (word, BUILD_FRAME's own output)
CCTX_DNS_RX_LEN		EQU 36	; &S11_FRAME_LENGTH (word, PARSE_REPLY_FRAME's input)
CCTX_PING_BUILD_DESC	EQU 38	; &PING_ICMP_BUILD_DESC (F_PING's own echo-request scratch)
CCTX_PING_REPLY_DESC	EQU 40	; &PING_ICMP_REPLY_DESC (F_PING's own echo-reply scratch)
CCTX_UDP_CTX_BASE	EQU 42	; &UNET_UDP_CTX (2 * UNET_UDP_CTX_SIZE bytes)
CCTX_S9_LOCAL_PORT	EQU 44	; &S9_LOCAL_PORT (word; +2/+4 reach REMOTE_PORT/EXPECT_REMOTE_PORT)
CCTX_SIZE		EQU 46

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
CFN_COUNT		EQU 31

	ENDIF
