; Backend-neutral polling Ethernet driver ABI for Stage 7.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_NETDRV_INC
	DEFINE	_NETDRV_INC

NETDRV_CONFIG_VERSION	EQU 1
NETDRV_CONFIG_LENGTH	EQU 15
NETDRV_CFG_VERSION	EQU 0
NETDRV_CFG_LENGTH	EQU 1
NETDRV_CFG_MODE		EQU 2
NETDRV_CFG_SLOT		EQU 3
NETDRV_CFG_IDPORT	EQU 4
NETDRV_CFG_BASE		EQU 6
NETDRV_CFG_MAC_FLAGS	EQU 8
NETDRV_CFG_MAC		EQU 9

NETDRV_MODE_AUTO	EQU 0
NETDRV_MODE_EXPLICIT	EQU 1
NETDRV_MAC_OVERRIDE	EQU 1

NETDRV_OK		EQU 0
NETDRV_ERR_PARAMETER	EQU 21
NETDRV_ERR_CONFIG	EQU 22
NETDRV_ERR_CANCELLED	EQU 23
NETDRV_ERR_UNREACHABLE	EQU 24
NETDRV_ERR_PROTOCOL	EQU 25
NETDRV_ERR_FILE_IO	EQU 26
NETDRV_ERR_DNS_NXDOMAIN EQU 27
NETDRV_ERR_DNS_NO_ANSWER EQU 28
NETDRV_ERR_CLOCK	EQU 29
NETDRV_ERR_LINK_DOWN	EQU EL3_ERR_LINK_TIMEOUT

; Any caller-owned buffer must fit wholly in ordinary address space, must not
; wrap, and must not overlap the loaded DLL window. Standalone Stage 7 EXEs use
; WIN1 buffers and set NETDRV_DLL_WINDOW=0. A future DLL defines it as 1 or 2.
NETDRV_DLL_NONE		EQU 0
NETDRV_DLL_WIN1		EQU 1
NETDRV_DLL_WIN2		EQU 2

	IFNDEF NETDRV_DLL_WINDOW
NETDRV_DLL_WINDOW	EQU NETDRV_DLL_NONE
	ENDIF

; WAIT_TICK loop count. Every deadline in the kit is counted in these quanta
; against a nominal millisecond, so the count decides whether a timeout means
; what it says. The loop is five memory accesses per iteration and the Sprinter
; bus aligns each one to a 6 T slot in turbo, so the 26 T the 21 MHz arithmetic
; assumes cost about 49 in practice: NETPROF measured 10000 quanta at 19 wall
; seconds with the textbook 808, and this count is sized from that measurement.
; Not to be confused with EL3_CYCLE_COUNT -- a CYCLES21 quantum is a documented
; hardware *minimum* and is meant to stay long.
NETTIME_TICK_LOOP	EQU 425

; ARP attempt schedule, shared by every resolver in the kit (tcp_transport,
; udp_transport and PING each run their own loop against the same contract).
; NETPROF on a real Sprinter needs about five seconds before its first request
; is answered, and answers a second cold-cache resolve in the same process
; instantly. Retrying faster does not shorten that window -- two NETPROF runs,
; one asking twice in five seconds and one asking five times, both resolved at
; about the same wall time -- so it is the path, not the request, that is not
; ready: DISCOVER global-resets the adapter at every program start, the 10baseT
; link drops and comes back, and the switch port takes seconds to forward
; again. The schedule therefore has to *cover* that window rather than beat it,
; which is why the opening ARP_FAST_ATTEMPTS run out to six seconds before the
; documented two-second attempts take over. A request is 42 bytes on a local
; segment; asking again costs nothing worth counting.
; Retry counters count down from ARP_ATTEMPTS_MAX, so the attempt that answered
; is ARP_ATTEMPTS_MAX + 1 minus what is left, and an attempt is a fast one
; while what is left is at least ARP_FAST_LEFT.
ARP_ATTEMPTS_MAX	EQU 14
ARP_FAST_ATTEMPTS	EQU 12
ARP_FAST_LEFT		EQU ARP_ATTEMPTS_MAX - ARP_FAST_ATTEMPTS + 1
ARP_FIRST_MS		EQU 500
ARP_RETRY_MS		EQU 2000

	ENDIF
