; Shared BSS_* region-offset table for UNET_DLL, used by BOTH assemblies:
;
;   unet509b.asm (hot image): defines DLL_BSS EQU $ (the real in-image
;   reservation address) before including this file, then reserves
;   DLL_BSS_SIZE bytes with `DLL_BSS DS DLL_BSS_SIZE,0`.
;
;   unet509b_cold.asm (cold blob): defines DLL_BSS EQU 0 (a dummy -- the
;   cold blob has no BSS of its own and never reads or writes through
;   these symbols) purely so its own `INCLUDE "memory.inc"` -> UNET_DLL ->
;   memory_dll.inc resolves without needing a second, divergent copy of
;   these offsets. tcp.asm/ipv4.asm/udp.asm/icmp.asm/ethernet.asm compile
;   into the cold blob unmodified and never reference a memory.inc symbol
;   by address (verified: they take every buffer as a descriptor pointer
;   in a register); this file exists only so their own `INCLUDE
;   "memory.inc"` lines have something consistent to resolve against.
;
; Every offset here is a literal (the relocation rule: never a computed
; difference of two addresses). SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_UNET509B_BSS_INC
	DEFINE	_UNET509B_BSS_INC

; BSS_TX is only ARP_FRAME_LENGTH (60) bytes, not a full TCP_MSS+headers
; reservation: TCP/ICMP segment building never needs to read the RX buffer
; at the same moment (any inbound payload a reply might ACK is already
; copied out before SEND_SEGMENT/F_PING build the reply -- see
; tcp_transport.asm's own TCPX_TX_BUFFER comment), so that traffic reuses
; the otherwise-idle RX buffer instead (the same trick UDP's own
; UDPX_TX_BUFFER already uses). ARP request/reply building is NOT safe to
; alias this way -- ARP_BUILD_REPLY reads fields from the very request
; frame it is still writing the reply into -- so it keeps this small,
; separate buffer, sized for exactly one 60-byte ARP frame.
BSS_TX		EQU 0x0000	; 60   STAGE9_TX_BUFFER (ARP request/reply only)
BSS_RX		EQU 0x003C	; 1514 STAGE9_RX_BUFFER (also EEPROM_BUFFER/S9_ENV_BUFFER/UDPX_TX_BUFFER/TCPX_TX_BUFFER overlay)
BSS_PEND0	EQU 0x0626	; 536  S11_PENDING0
BSS_PEND1	EQU 0x083E	; 536  S11_PENDING1
BSS_CTX0	EQU 0x0A56	; 40   S11_CONTEXT0
BSS_CTX1	EQU 0x0A7E	; 40   S11_CONTEXT1
BSS_CTX_SCRATCH	EQU 0x0AA6	; 40   S11_CONTEXT_SCRATCH (route resolve for DNS/UDP/PING)
BSS_S11		EQU 0x0ACE	; 105  S11_STATE_BASE (packed DLL-only layout)
; BSS_RT was 400 (a round-number guess from early phases); DNS's added
; scratch fields brought real usage (BSS_RT_USED, memory_dll.inc) to 244 --
; 264 keeps a 20-byte margin instead of carrying ~136 bytes of pure guess
; padding against the hard image ceiling.
BSS_RT		EQU 0x0B37	; 244  RUNTIME_BASE (EL3_*/NETDRV_*/NET_*/ARP/NETTIME_*/S9_*/DNS_*)
BSS_UNET	EQU 0x0C2B	; 122  dispatcher scalars and compact COLD_CTX
DLL_BSS_SIZE	EQU 0x0CA5	; 3237 total; cold stack lives at WIN0 3F80..3FFF
	ASSERT BSS_TX + 60 <= BSS_RX
	ASSERT BSS_RX + 1514 <= BSS_PEND0
	ASSERT BSS_PEND0 + 536 <= BSS_PEND1
	ASSERT BSS_PEND1 + 536 <= BSS_CTX0
	ASSERT BSS_CTX0 + 40 <= BSS_CTX1
	ASSERT BSS_CTX1 + 40 <= BSS_CTX_SCRATCH
	ASSERT BSS_CTX_SCRATCH + 40 <= BSS_S11
	ASSERT BSS_S11 + 105 <= BSS_RT
	ASSERT BSS_RT + 244 <= BSS_UNET
	ASSERT BSS_UNET + 122 <= DLL_BSS_SIZE

	ENDIF
