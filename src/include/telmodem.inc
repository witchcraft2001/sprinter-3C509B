; TELNET modem-page ABI.  The terminal and the native 3Com transport stay in
; WIN1/WIN2; ZMODEM/YMODEM code lives in a separate pageable WIN0 image.  The
; image is an internal part of TELNET.EXE: its stage-1 preloader streams it
; from the already opened EXE into a DSS page before entering the terminal.
; All addresses below are deliberately fixed inside TELNET's resident BSS so
; the independently assembled cold page has no link-time dependency on the
; main executable's instruction addresses.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_TELMODEM_INC
	DEFINE	_TELMODEM_INC

TELMODEM_MAX_SIZE	EQU 0x3F80	; preserve top 128 bytes of the cold page

; Cold-entry selectors.  They are an ABI between MAIN.MODEM.CALL and the
; separately assembled page dispatcher embedded in TELNET.EXE.
TELMODEM_FN_Z_RECEIVE	EQU 0
TELMODEM_FN_Z_REPLAY	EQU 1
TELMODEM_FN_Y_RECEIVE	EQU 2
TELMODEM_FN_Y_RECEIVE_G	EQU 3
TELMODEM_FN_Y_SEND	EQU 4

; The preloader writes these immutable boot facts before it enters MAIN.  They
; deliberately precede the terminal BSS clear (which starts at +0x700), so a
; session reset cannot lose the allocated cold-page mapping.
TELMODEM_BOOT_BASE	EQU RUNTIME_BASE + 0x6F0
TELMODEM_BOOT_PHYS_PAGE EQU TELMODEM_BOOT_BASE + 0
TELMODEM_BOOT_DSS_PAGE	EQU TELMODEM_BOOT_BASE + 1
TELMODEM_BOOT_BLOCK_ID	EQU TELMODEM_BOOT_BASE + 2
TELMODEM_BOOT_VALID	EQU TELMODEM_BOOT_BASE + 3

; The monolithic executable owns WIN0. These resident WIN2 bytes mirror the
; Fido Editor wrt_dss/wrt_p0/wrt_p1 table used by every syscall trampoline.
TELNET_SYS_DSS_PAGE	EQU TELMODEM_BOOT_BASE + 4
TELNET_SYS_P0_PAGE	EQU TELMODEM_BOOT_BASE + 5
TELNET_SYS_P1_PAGE	EQU TELMODEM_BOOT_BASE + 6

; Resident WIN1 trampoline addresses. The hot image starts at 0x4000 and
; reserves 0x4000..0x40ff for this table before MAIN begins at 0x4100.
TELNET_SYS_BIOS_TRAMP	EQU 0x4000
TELNET_SYS_DSS_TRAMP	EQU 0x4020
TELNET_SYS_MOUSE_TRAMP	EQU 0x4040
TELNET_SYS_INT_TRAMP	EQU 0x4060

; The terminal's resident BSS begins at RUNTIME_BASE+0x700.  Its fixed fields
; through TRANSFER_STAGE finish at +0x811.  Keep transfer administration and
; state immediately after that range; the normal WIN2 stack starts at
; PAGE_BASE+0x3FF0 and all larger Z/Y buffers retain their established
; locations in the lower part of that page.
TELMODEM_LOADER_BASE	EQU RUNTIME_BASE + 0x812
TELMODEM_READY		EQU TELMODEM_LOADER_BASE + 0
TELMODEM_BLOCK_ID	EQU TELMODEM_LOADER_BASE + 1
TELMODEM_PHYS_PAGE	EQU TELMODEM_LOADER_BASE + 2
TELMODEM_DSS_PAGE	EQU TELMODEM_LOADER_BASE + 3

; Cold code reaches every WIN1 callback through these pointers.  A pointer
; table keeps the cold page position-independent from TELNET's hot layout.
TELMODEM_API_BASE	EQU TELMODEM_LOADER_BASE + 4
TELMODEM_API_DSS	EQU TELMODEM_API_BASE + 0
TELMODEM_API_BIOS	EQU TELMODEM_API_BASE + 2
TELMODEM_API_INT		EQU TELMODEM_API_BASE + 4
TELMODEM_API_OUTPUT	EQU TELMODEM_API_BASE + 6
TELMODEM_API_PROCESS	EQU TELMODEM_API_BASE + 8
TELMODEM_API_RX_DRAIN	EQU TELMODEM_API_BASE + 10
TELMODEM_API_RX_WAIT	EQU TELMODEM_API_BASE + 12
TELMODEM_API_NET_SEND	EQU TELMODEM_API_BASE + 14
TELMODEM_API_DELAY	EQU TELMODEM_API_BASE + 16
TELMODEM_API_TEST_FILL	EQU TELMODEM_API_BASE + 18
TELMODEM_API_END		EQU TELMODEM_API_BASE + 20

TELMODEM_ZM_STATE_BASE	EQU TELMODEM_API_END
TELMODEM_ZM_STATE_SIZE	EQU 137
TELMODEM_YM_STATE_BASE	EQU TELMODEM_ZM_STATE_BASE + TELMODEM_ZM_STATE_SIZE
TELMODEM_YM_STATE_SIZE	EQU 43
TELMODEM_BSS_END	EQU TELMODEM_YM_STATE_BASE + TELMODEM_YM_STATE_SIZE

; Values owned by TELNET's terminal BSS.  The cold module only reads/writes
; these scalar fields; the equalities in telnet.asm make a drift fail assembly.
TELMODEM_CANCELLED	EQU RUNTIME_BASE + 0x76A
TELMODEM_YM_C_PENDING	EQU RUNTIME_BASE + 0x801
TELMODEM_TRANSFER_STAGE EQU RUNTIME_BASE + 0x811
	ENDIF
