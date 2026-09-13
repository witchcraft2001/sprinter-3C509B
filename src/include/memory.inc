; Runtime layout shared by the standalone diagnostics.
; These addresses are populated at runtime and are not emitted into an EXE.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_MEMORY_INC
	DEFINE	_MEMORY_INC

	IFDEF	UNET_DLL
; UNET509B.DLL carries its own state as in-image BSS (DLL_BSS, declared by
; src/dll/unet509b.asm before this INCLUDE) instead of the fixed
; RUNTIME_BASE/PAGE_BASE addresses below -- those belong to the consumer's
; own address space and a libman DLL must never write there. See
; memory_dll.inc's header comment.
	INCLUDE	"memory_dll.inc"
	ELSE

; PAGE_BASE is the window a program maps its private DSS page over. Every
; utility here loads at 8080h, owns WIN2 and maps its page over WIN1, so the
; default is 4000h. Stage 12 is the exception: WGET's image fills a whole
; window, so it loads into WIN1 and claims WIN2 instead -- the arrangement the
; sibling RTL8019A kit uses for its large utilities. The stack must end up in
; the claimed window either way, because BIOS WIN_MOVE maps the video page over
; WIN1 on every scrolled console line and restores SLOT1 from a POP taken while
; that page is still mapped.
	IFNDEF PAGE_BASE
	IFDEF STAGE12_LAYOUT
PAGE_BASE		EQU 0x8000
	ELSE
PAGE_BASE		EQU 0x4000
	ENDIF
	ENDIF

	IFNDEF RUNTIME_BASE
RUNTIME_BASE		EQU 0xB000
	ENDIF
CMDLINE_SOURCE		EQU RUNTIME_BASE + 0x00 ; word
CLI_READER_PTR		EQU RUNTIME_BASE + 0x02 ; word
CLI_READER_REMAIN	EQU RUNTIME_BASE + 0x04
CLI_TOKEN_LEN		EQU RUNTIME_BASE + 0x05
CLI_MODE		EQU RUNTIME_BASE + 0x06
CLI_SEEN		EQU RUNTIME_BASE + 0x07
CLI_SLOT		EQU RUNTIME_BASE + 0x08
CLI_VERBOSE		EQU RUNTIME_BASE + 0x09
CLI_BASE_AUTO		EQU RUNTIME_BASE + 0x0A
CLI_IDPORT		EQU RUNTIME_BASE + 0x0B ; word
CLI_BASE		EQU RUNTIME_BASE + 0x0D ; word
CLI_COUNT		EQU RUNTIME_BASE + 0x0F ; word

EL3_IDPORT		EQU RUNTIME_BASE + 0x20 ; word
EL3_BASE		EQU RUNTIME_BASE + 0x22 ; word
EL3_LAST_STAGE		EQU RUNTIME_BASE + 0x24
EL3_LAST_TICKS		EQU RUNTIME_BASE + 0x25 ; word, CYCLES21 wait quanta
EL3_LAST_STATUS		EQU RUNTIME_BASE + 0x27 ; word
EL3_MAC			EQU RUNTIME_BASE + 0x29 ; six bytes

EL3_LAST_COMMAND	EQU RUNTIME_BASE + 0x30 ; word
EL3_EXPECT_MEDIA	EQU RUNTIME_BASE + 0x32 ; word
EL3_COUNT_RESET		EQU RUNTIME_BASE + 0x34 ; word
EL3_COUNT_TIMEOUT	EQU RUNTIME_BASE + 0x36 ; word
EL3_COUNT_RX		EQU RUNTIME_BASE + 0x38 ; word
EL3_COUNT_TX		EQU RUNTIME_BASE + 0x3A ; word
EL3_COUNT_DROP		EQU RUNTIME_BASE + 0x3C ; word
EL3_COUNT_FRAME		EQU RUNTIME_BASE + 0x3E ; word
EL3_SNAPSHOT_BUFFER	EQU RUNTIME_BASE + 0x40 ; 60 bytes
EL3_VERIFY_FIELD	EQU RUNTIME_BASE + 0x80
EL3_VERIFY_EXPECTED	EQU RUNTIME_BASE + 0x81 ; word
EL3_VERIFY_ACTUAL	EQU RUNTIME_BASE + 0x83 ; word
EL3_LAST_RX_STATUS	EQU RUNTIME_BASE + 0x85 ; word
EL3_LAST_TX_STATUS	EQU RUNTIME_BASE + 0x87
EL3_RX_REQUIRED		EQU RUNTIME_BASE + 0x88 ; word
; Written only when EL3_VALIDATE_DIAG is defined (EL3EEP). They report which
; VALIDATE check rejected an EEPROM image and the checksum lanes it computed,
; so a card the project refuses can be diagnosed from its own dump.
EL3_VALIDATE_FAIL	EQU RUNTIME_BASE + 0x8A ; EL3_VFAIL_*
EL3_PRIMARY_CALC	EQU RUNTIME_BASE + 0x8B ; word, lanes in word 0F order
EL3_SECONDARY_CALC	EQU RUNTIME_BASE + 0x8D ; word, lanes in word 17 order
	ASSERT EL3_SECONDARY_CALC + 2 <= RUNTIME_BASE + 0x90

EL3LB_MEMORY_BLOCK	EQU RUNTIME_BASE + 0x90
EL3LB_REMAINING		EQU RUNTIME_BASE + 0x91
EL3LB_MATRIX_OK		EQU RUNTIME_BASE + 0x92 ; word
EL3LB_BURST_OK		EQU RUNTIME_BASE + 0x94 ; word
EL3LB_RUN_OK		EQU RUNTIME_BASE + 0x96
EL3LB_INPUT_LENGTH	EQU RUNTIME_BASE + 0x98 ; word
EL3LB_EXPECT_LENGTH	EQU RUNTIME_BASE + 0x9A ; word
EL3LB_ACTUAL_LENGTH	EQU RUNTIME_BASE + 0x9C ; word
EL3LB_PATTERN		EQU RUNTIME_BASE + 0x9E
EL3LB_SAVED_STAGE	EQU RUNTIME_BASE + 0xA0
EL3LB_SAVED_TICKS	EQU RUNTIME_BASE + 0xA1 ; word
EL3LB_SAVED_STATUS	EQU RUNTIME_BASE + 0xA3 ; word
EL3LB_SAVED_RX		EQU RUNTIME_BASE + 0xA5 ; word
EL3LB_SAVED_TX		EQU RUNTIME_BASE + 0xA7
EL3LB_SAVED_REQUIRED	EQU RUNTIME_BASE + 0xA8 ; word
EL3LB_FAIL_CODE		EQU RUNTIME_BASE + 0xAA
EL3LB_WAIT_TICKS	EQU RUNTIME_BASE + 0xAB ; word, private RX wait deadline

; Stage 6 application state. The packet data itself lives in one mapped DSS
; page at 4000h; these small fields remain resident while WIN1 is remapped.
S6_MEMORY_BLOCK		EQU RUNTIME_BASE + 0x200
S6_REMAINING		EQU RUNTIME_BASE + 0x201 ; word
S6_WAIT_TICKS		EQU RUNTIME_BASE + 0x203 ; word
S6_FAIL_CODE		EQU RUNTIME_BASE + 0x205
S6_SAVED_STAGE		EQU RUNTIME_BASE + 0x206
S6_SAVED_TICKS		EQU RUNTIME_BASE + 0x207 ; word
S6_SAVED_STATUS		EQU RUNTIME_BASE + 0x209 ; word
S6_SAVED_RX		EQU RUNTIME_BASE + 0x20B ; word
S6_SAVED_TX		EQU RUNTIME_BASE + 0x20D
S6_SAVED_REQUIRED	EQU RUNTIME_BASE + 0x20E ; word
S6_SEQUENCE		EQU RUNTIME_BASE + 0x210
S6_ACTUAL_LENGTH	EQU RUNTIME_BASE + 0x211 ; word

CLI_DEST_MAC		EQU RUNTIME_BASE + 0x220 ; six bytes
CLI_ETHERTYPE		EQU RUNTIME_BASE + 0x226 ; word, host numeric value
CLI_LENGTH		EQU RUNTIME_BASE + 0x228 ; word
CLI_PATTERN		EQU RUNTIME_BASE + 0x22A
CLI_WAIT		EQU RUNTIME_BASE + 0x22B ; word, CYCLES21 wait quanta
CLI_HEXDUMP		EQU RUNTIME_BASE + 0x22D

CRC32_VALUE		EQU RUNTIME_BASE + 0x230 ; four bytes, little endian
CRC32_REMAINING		EQU RUNTIME_BASE + 0x234 ; word

; Stage 7 resident state. Packet storage is caller-owned in one mapped WIN1
; page; these addresses are private bookkeeping and are never part of NETDRV's
; public ABI.
NETDRV_CONFIG		EQU RUNTIME_BASE + 0x240 ; NETDRV_CONFIG_LENGTH bytes
NETDRV_ACTIVE		EQU RUNTIME_BASE + 0x250
NETDRV_MEMORY_BLOCK	EQU RUNTIME_BASE + 0x251
NETDRV_PAGE_ALLOCATED	EQU RUNTIME_BASE + 0x252
	IFDEF STAGE10_PAGE_LAYOUT
	IFDEF STAGE13_LAYOUT
; FTP's copy is defined in the STAGE13_LAYOUT F13 block below, next to the
; reserve it is carved from. A literal here is what silently walked it into
; the middle of S11_APP_BUFFER the first time the S11 block moved: the
; address kept assembling and kept pointing at a live receive buffer.
	ELSE
	IFDEF STAGE12_LAYOUT
NETDRV_FAIL_CODE	EQU PAGE_BASE + 0x2D5F ; page-backed; Stage 12 cleanup keeps status on stack
	ELSE
NETDRV_FAIL_CODE	EQU 0xBEF1 ; survives release of the mapped DSS page
	ENDIF
	ENDIF
	ELSE
NETDRV_FAIL_CODE	EQU RUNTIME_BASE + 0x253
	ENDIF
NETDRV_SAVED_IX		EQU RUNTIME_BASE + 0x254 ; word
NETDRV_BUFFER_PTR	EQU RUNTIME_BASE + 0x256 ; word
NETDRV_BUFFER_LEN	EQU RUNTIME_BASE + 0x258 ; word
NETDRV_STATION_MAC	EQU RUNTIME_BASE + 0x25A ; six bytes, owned by NETDRV

NET_LOCAL_IP		EQU RUNTIME_BASE + 0x260 ; four bytes
NET_NETMASK		EQU RUNTIME_BASE + 0x264 ; four bytes
NET_GATEWAY		EQU RUNTIME_BASE + 0x268 ; four bytes
NET_TARGET_IP		EQU RUNTIME_BASE + 0x26C ; four bytes
NET_NEXT_HOP_IP		EQU RUNTIME_BASE + 0x270 ; four bytes
NET_RESULT_MAC		EQU RUNTIME_BASE + 0x274 ; six bytes
NETDRV_SELECTED_SLOT	EQU RUNTIME_BASE + 0x27A
NETDRV_SELECTED_BASE	EQU RUNTIME_BASE + 0x27B ; word

ARP_CACHE		EQU RUNTIME_BASE + 0x280 ; four 16-byte entries
ARP_CACHE_ENTRY_SIZE	EQU 16
ARP_CACHE_COUNT		EQU 4
ARP_CACHE_CLOCK		EQU RUNTIME_BASE + 0x2C0 ; word seconds
ARP_RX_LENGTH		EQU RUNTIME_BASE + 0x2C2 ; word
ARP_RETRY_LEFT		EQU RUNTIME_BASE + 0x2C4
ARP_WAIT_LEFT		EQU RUNTIME_BASE + 0x2C5 ; word milliseconds
NET_DNS1		EQU RUNTIME_BASE + 0x2C7 ; four bytes
NET_DNS2		EQU RUNTIME_BASE + 0x2CB ; four bytes

DHCP_XID		EQU RUNTIME_BASE + 0x2D0 ; four bytes
DHCP_MSG_TYPE		EQU RUNTIME_BASE + 0x2D4
DHCP_OFFERED_IP		EQU RUNTIME_BASE + 0x2D5 ; four bytes
DHCP_SERVER_ID		EQU RUNTIME_BASE + 0x2D9 ; four bytes
DHCP_MASK		EQU RUNTIME_BASE + 0x2DD ; four bytes
DHCP_ROUTER		EQU RUNTIME_BASE + 0x2E1 ; four bytes
DHCP_DNS1		EQU RUNTIME_BASE + 0x2E5 ; four bytes
DHCP_DNS2		EQU RUNTIME_BASE + 0x2E9 ; four bytes
DHCP_LEASE_SECS		EQU RUNTIME_BASE + 0x2ED ; four bytes, host-order LE
DHCP_DEADLINE		EQU RUNTIME_BASE + 0x2F1 ; word seconds/ticks
DHCP_RX_LENGTH		EQU RUNTIME_BASE + 0x2F3 ; word
DHCP_PARSE_STAGE	EQU RUNTIME_BASE + 0x2F5
DHCP_OPTION_SEEN	EQU RUNTIME_BASE + 0x2F6

; Stage 8 resident state. Packet bytes remain in the single caller-owned WIN1
; page. Descriptors are small and intentionally contain pointers/capacities.
	IFDEF STAGE10_PAGE_LAYOUT
PING_STATE_BASE		EQU PAGE_BASE + 0x3500
	ELSE
PING_STATE_BASE		EQU RUNTIME_BASE + 0x800
	ENDIF
PING_FLAGS		EQU PING_STATE_BASE + 0x000
PING_SEEN		EQU PING_STATE_BASE + 0x001
PING_COUNT		EQU PING_STATE_BASE + 0x002 ; word
PING_SIZE		EQU PING_STATE_BASE + 0x004 ; word
PING_TIMEOUT_MS		EQU PING_STATE_BASE + 0x006 ; word
PING_TTL		EQU PING_STATE_BASE + 0x008
PING_HELP		EQU PING_STATE_BASE + 0x009
	IFDEF STAGE10_PAGE_LAYOUT
PING_TARGET_TEXT	EQU PAGE_BASE + 0x3700 ; 255-byte hostname/IPv4 text
	ELSE
PING_TARGET_TEXT	EQU PING_STATE_BASE + 0x00A ; 16 bytes
	ENDIF
PING_IDENTIFIER		EQU PING_STATE_BASE + 0x01A ; word
PING_SEQUENCE		EQU PING_STATE_BASE + 0x01C ; word
PING_IP_ID		EQU PING_STATE_BASE + 0x01E ; word
PING_SENT		EQU PING_STATE_BASE + 0x020 ; word
PING_RECEIVED		EQU PING_STATE_BASE + 0x022 ; word
PING_UNREACHABLE	EQU PING_STATE_BASE + 0x024
PING_RX_LENGTH		EQU PING_STATE_BASE + 0x025 ; word
PING_FRAME_RESULT	EQU PING_STATE_BASE + 0x027
PING_DRAIN_LEFT		EQU PING_STATE_BASE + 0x028
	IFDEF STAGE10_PAGE_LAYOUT
PING_EXIT_CODE		EQU 0xBEF0 ; survives release of the mapped DSS page
	ELSE
PING_EXIT_CODE		EQU PING_STATE_BASE + 0x029
	ENDIF
PING_PRIMARY_ERROR	EQU PING_STATE_BASE + 0x02A
PING_INCOMING_IP	EQU PING_STATE_BASE + 0x02B ; four bytes
PING_REPLY_IP		EQU PING_STATE_BASE + 0x02F ; four bytes

IPV4_BUILD_DESC		EQU PING_STATE_BASE + 0x040 ; 14 bytes
IPV4_PARSE_DESC		EQU PING_STATE_BASE + 0x050 ; 18 bytes
ICMP_BUILD_DESC		EQU PING_STATE_BASE + 0x070 ; 12 bytes
ICMP_REPLY_DESC		EQU PING_STATE_BASE + 0x080 ; 8 bytes
ICMP_COPY_DESC		EQU PING_STATE_BASE + 0x090 ; 8 bytes

	IFDEF STAGE9_LAYOUT
NETTIME_STATE_BASE	EQU RUNTIME_BASE + 0x2D0
	ELSE
NETTIME_STATE_BASE	EQU RUNTIME_BASE + 0x8A0
	ENDIF
NETTIME_QPS		EQU NETTIME_STATE_BASE + 0x00 ; word
NETTIME_QUANTA_LEFT	EQU NETTIME_STATE_BASE + 0x02 ; word
NETTIME_START_WALL	EQU NETTIME_STATE_BASE + 0x04 ; word, second within hour
NETTIME_WALL_LIMIT	EQU NETTIME_STATE_BASE + 0x06 ; word
NETTIME_TIMEOUT_MS	EQU NETTIME_STATE_BASE + 0x08 ; word
NETTIME_CAL_COUNT	EQU NETTIME_STATE_BASE + 0x0A ; word
NETTIME_CAL_SECOND	EQU NETTIME_STATE_BASE + 0x0C
NETTIME_ACC_LO		EQU NETTIME_STATE_BASE + 0x0D ; word
NETTIME_ACC_HI		EQU NETTIME_STATE_BASE + 0x0F ; word
NETTIME_QUANTA_TOTAL	EQU NETTIME_STATE_BASE + 0x11 ; word
NETTIME_MS_PER_QUANTUM	EQU NETTIME_STATE_BASE + 0x13 ; word
NETTIME_ELAPSED_MS	EQU NETTIME_STATE_BASE + 0x15 ; word

	; Stage 9 compact application state. Large packet/file storage remains in the
	; one mapped DSS page; this bookkeeping is resident and below STACK_TOP.
	IFDEF STAGE9_LAYOUT
	IFDEF STAGE13_LAYOUT
	IFDEF TCPX_LARGE_MSS
; FTP at MSS 1460. This page is the tightest in the kit -- it carries two
; pending regions and two contexts -- so the staging buffers grow to hold a
; whole 1,514-byte frame (mandatory: READ_FRAME rejects a frame larger than
; the capacity it is given, which at 1024 would drop every data segment) and
; the file buffer pays for it.
;
; The data area starts 2 KiB into WIN2, not at PAGE_BASE. In the standard
; DSS layout WIN1+WIN2 are one contiguous 0x4100..0xBFFF region the program
; owns outright, so where code ends and data begins is this file's choice,
; and FTP's image runs to S13_IMAGE_LIMIT (ftp.asm's ASSERT). Those 2 KiB
; are what pay for EL3_SESSION_RX, TCPX_DIRECT_RX and FAST_DATAPATH in FTP:
; measured on the actual EXE, the fused read+checksum+deliver receive path
; is the 2x on the CPU side of RETR, and nothing cheaper fits.
;
; They come out of the file buffer, which measured as free to give: halving
; the number of DSS_WRITE calls (2 KiB -> 4 KiB) changed the live rate by
; nothing, so the write cost is per byte, not per call. What the size must
; still allow is one whole segment delivered straight into the buffer plus a
; sector of carry-over (GET_LOOP writes whole sectors and slides the
; remainder down), which is the ASSERT below.
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0800
STAGE9_TX_CAPACITY	EQU 0x0600
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0E00
STAGE9_RX_CAPACITY	EQU 0x0600
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x1400
STAGE9_FILE_CAPACITY	EQU 0x0800	; 4 * 512
STAGE9_MAX_FRAME	EQU 14 + 20 + 20 + 1460
S13_IMAGE_LIMIT		EQU STAGE9_TX_BUFFER
	ASSERT STAGE9_FILE_CAPACITY >= 1460 + 512
	ELSE
; Same TX/RX split as STAGE12_LAYOUT (WGET); the file buffer is smaller
; because it doubles as STOR's read-chunk source and the page also carries a
; second full pending region and context for the data channel.
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0000
STAGE9_TX_CAPACITY	EQU 0x0400
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0400
STAGE9_RX_CAPACITY	EQU 0x0400
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x0800
STAGE9_FILE_CAPACITY	EQU 0x1000
STAGE9_MAX_FRAME	EQU 14 + 20 + 20 + 536
	ENDIF
	ELSE
	IFDEF STAGE12_LAYOUT
	IFDEF TCPX_LARGE_MSS
; DLDIRECT at MSS 1460 (tcp.inc): both staging buffers have to hold a whole
; 1,514-byte Ethernet frame, not a 590-byte one. The receive buffer matters
; most -- the two-phase receive only reads a 54-byte header into it for a fast
; in-order data segment, but a segment the fast predicate declines is read
; whole and handed to PROCESS_FRAME, and a capacity below the frame length
; would drop it into an endless drop/retransmit loop instead. The 2 KiB the
; two buffers gain comes out of the caller batching buffer, which still takes
; three whole segments (4,380 of 5,120 bytes) per public RECV -- more payload
; per call than the eleven 536-byte segments it batched before.
	IFDEF WGET_LAYOUT
; WGET: the same arrangement as FTP's (see the STAGE13_LAYOUT block above).
; The data area starts 2 KiB into WIN2 so the image can carry EL3_SESSION_RX,
; and the 2 KiB come out of the disk batch buffer, whose size is not a lever
; (DSS_WRITE cost is per byte). 3 KiB still takes one whole segment straight
; from the FIFO plus a sector of carry-over, which is all the whole-sector
; flush needs (wget.asm's FLUSH_SECTORS).
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0800
STAGE9_TX_CAPACITY	EQU 0x0600
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0E00
STAGE9_RX_CAPACITY	EQU 0x0600
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x1400
STAGE9_FILE_CAPACITY	EQU 0x0C00	; 6 * 512
STAGE9_MAX_FRAME	EQU 14 + 20 + 20 + 1460
S12_IMAGE_LIMIT		EQU STAGE9_TX_BUFFER
	ASSERT STAGE9_FILE_CAPACITY >= 1460 + 512
	ELSE
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0000
STAGE9_TX_CAPACITY	EQU 0x0600
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0600
STAGE9_RX_CAPACITY	EQU 0x0600
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x0C00
STAGE9_FILE_CAPACITY	EQU 0x1400
STAGE9_MAX_FRAME	EQU 14 + 20 + 20 + 1460
	ENDIF
	ELSE
; WGET batches disk writes in 6 KiB and spends the two KiB that used to sit
; here on the TCP receive window instead: write batching only saves DSS calls,
; while the window decides how many segments the peer may keep in flight, and
; the second is what the transfer rate is made of. HTTP never needs the
; 1514-byte UDP diagnostic packets used by Stage 9.
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0000
STAGE9_TX_CAPACITY	EQU 0x0400
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0400
STAGE9_RX_CAPACITY	EQU 0x0400
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x0800
STAGE9_FILE_CAPACITY	EQU 0x1800
STAGE9_MAX_FRAME	EQU 14 + 20 + 20 + 536
	ENDIF
	ELSE
STAGE9_TX_BUFFER	EQU PAGE_BASE + 0x0000
STAGE9_TX_CAPACITY	EQU 0x0800
STAGE9_RX_BUFFER	EQU PAGE_BASE + 0x0800
STAGE9_RX_CAPACITY	EQU 0x0800
STAGE9_FILE_BUFFER	EQU PAGE_BASE + 0x1000
STAGE9_FILE_CAPACITY	EQU 0x2000
	ENDIF
	ENDIF
	IFDEF STAGE10_PAGE_LAYOUT
STAGE9_SCRATCH		EQU PAGE_BASE + 0x3800
STAGE9_SCRATCH_CAPACITY EQU 0x0600
	ELSE
STAGE9_SCRATCH		EQU PAGE_BASE + 0x3000
STAGE9_SCRATCH_CAPACITY EQU 0x1000
	ENDIF
	IFNDEF STAGE12_LAYOUT
	IFNDEF STAGE13_LAYOUT
STAGE9_MAX_FRAME	EQU 14 + 20 + 8 + 1472
	ENDIF
	ENDIF

S9_STATE_BASE		EQU RUNTIME_BASE + 0x300
S9_FLAGS		EQU S9_STATE_BASE + 0x000
S9_SEEN			EQU S9_STATE_BASE + 0x001
S9_COUNT		EQU S9_STATE_BASE + 0x002 ; word
S9_SIZE			EQU S9_STATE_BASE + 0x004 ; word
S9_TIMEOUT_MS		EQU S9_STATE_BASE + 0x006 ; word
	IFDEF STAGE10_PAGE_LAYOUT
S9_TARGET_TEXT		EQU PAGE_BASE + 0x3700 ; 255-byte hostname/IPv4 text
	ELSE
S9_TARGET_TEXT		EQU S9_STATE_BASE + 0x008 ; 16 bytes
	ENDIF
S9_REMOTE_PORT		EQU S9_STATE_BASE + 0x018 ; word
S9_EXPECT_REMOTE_PORT	EQU S9_STATE_BASE + 0x01A ; word, zero accepts any TID
S9_LOCAL_PORT		EQU S9_STATE_BASE + 0x01C ; word
S9_SEQUENCE		EQU S9_STATE_BASE + 0x01E ; word
S9_IP_ID		EQU S9_STATE_BASE + 0x020 ; word
S9_ATTEMPTS		EQU S9_STATE_BASE + 0x022
S9_RX_LENGTH		EQU S9_STATE_BASE + 0x023 ; word
S9_DRAIN_LEFT		EQU S9_STATE_BASE + 0x025
	IFDEF STAGE10_PAGE_LAYOUT
	IFDEF STAGE13_LAYOUT
; As with NETDRV_FAIL_CODE above: defined in the F13 block below.
	ELSE
	IFDEF STAGE12_LAYOUT
S9_EXIT_CODE		EQU PAGE_BASE + 0x2D5E
	ELSE
S9_EXIT_CODE		EQU 0xBEF0 ; survives release of the mapped DSS page
	ENDIF
	ENDIF
	ELSE
S9_EXIT_CODE		EQU S9_STATE_BASE + 0x026
	ENDIF
S9_PRIMARY_ERROR	EQU S9_STATE_BASE + 0x027
S9_INCOMING_IP		EQU S9_STATE_BASE + 0x028 ; four bytes
S9_RX_SOURCE_PORT	EQU S9_STATE_BASE + 0x02C ; word
S9_RX_PAYLOAD		EQU S9_STATE_BASE + 0x02E ; word
S9_RX_PAYLOAD_LENGTH	EQU S9_STATE_BASE + 0x030 ; word
S9_REPLY_TTL		EQU S9_STATE_BASE + 0x032

S9_IPV4_BUILD_DESC	EQU S9_STATE_BASE + 0x040 ; 14 bytes
S9_IPV4_PARSE_DESC	EQU S9_STATE_BASE + 0x050 ; 18 bytes
S9_UDP_BUILD_DESC	EQU S9_STATE_BASE + 0x070 ; 14 bytes
S9_UDP_PARSE_DESC	EQU S9_STATE_BASE + 0x080 ; 20 bytes
S9_ICMP_COPY_DESC	EQU S9_STATE_BASE + 0x0A0 ; 8 bytes
S9_ICMP_REPLY_DESC	EQU S9_STATE_BASE + 0x0B0 ; 10 bytes

	IFDEF STAGE13_LAYOUT
; Just past the highest RUNTIME_BASE-aliased field FTP's own call graph
; touches (S9_TFTP_ERROR_DESC+10, ~0xB4EA) and clear of the F13 string block
; below, which starts only after S11_REMOTE_TEXT at PAGE_BASE+0x3700.
S9_ENV_BUFFER		EQU PAGE_BASE + 0x3500
	ELSE
	IFDEF STAGE12_LAYOUT
S9_ENV_BUFFER		EQU PAGE_BASE + 0x3B00 ; leaves the persistent WGET strings intact
	ELSE
S9_ENV_BUFFER		EQU STAGE9_SCRATCH ; 256-byte DSS ENV_GET destination
	ENDIF
	ENDIF
S9_TFTP_MODE		EQU S9_STATE_BASE + 0x180
S9_TFTP_FORCE		EQU S9_STATE_BASE + 0x181
S9_TFTP_FILE_HANDLE	EQU S9_STATE_BASE + 0x182
S9_TFTP_FILE_OPEN	EQU S9_STATE_BASE + 0x183
S9_TFTP_SERVER_PORT	EQU S9_STATE_BASE + 0x184 ; word, latched TID
S9_TFTP_REQUEST_PORT	EQU S9_STATE_BASE + 0x186 ; word
S9_TFTP_BLOCK		EQU S9_STATE_BASE + 0x188 ; word
S9_TFTP_BLOCK_SIZE	EQU S9_STATE_BASE + 0x18A ; word
S9_TFTP_RETRIES		EQU S9_STATE_BASE + 0x18C
S9_TFTP_FINAL		EQU S9_STATE_BASE + 0x18D
S9_TFTP_BUFFER_USED	EQU S9_STATE_BASE + 0x18E ; word
S9_TFTP_PACKET_DESC	EQU S9_STATE_BASE + 0x1A0 ; 16 bytes
S9_TFTP_BUILD_DESC	EQU S9_STATE_BASE + 0x1B0 ; 12 bytes
S9_TFTP_DATA_DESC	EQU S9_STATE_BASE + 0x1C0 ; 8 bytes
S9_TFTP_ACK_DESC	EQU S9_STATE_BASE + 0x1D0 ; 6 bytes
S9_TFTP_ERROR_DESC	EQU S9_STATE_BASE + 0x1E0 ; 10 bytes
	IFDEF STAGE10_PAGE_LAYOUT
S9_TFTP_HOST		EQU PAGE_BASE + 0x3700 ; shared hostname staging
S9_TFTP_REMOTE_NAME	EQU PAGE_BASE + 0x3500 ; 80 bytes
S9_TFTP_LOCAL_NAME	EQU PAGE_BASE + 0x3550 ; 96 bytes
	ELSE
S9_TFTP_HOST		EQU S9_STATE_BASE + 0x200 ; 22 bytes
S9_TFTP_REMOTE_NAME	EQU S9_STATE_BASE + 0x220 ; 80 bytes
S9_TFTP_LOCAL_NAME	EQU S9_STATE_BASE + 0x270 ; 96 bytes
	ENDIF

	ASSERT STAGE9_MAX_FRAME <= 1514
	ASSERT STAGE9_MAX_FRAME <= STAGE9_TX_CAPACITY
	ASSERT STAGE9_TX_BUFFER + STAGE9_TX_CAPACITY <= STAGE9_RX_BUFFER
	ASSERT STAGE9_RX_BUFFER + STAGE9_RX_CAPACITY <= STAGE9_FILE_BUFFER
	ASSERT STAGE9_FILE_BUFFER + STAGE9_FILE_CAPACITY <= STAGE9_SCRATCH
	ASSERT S9_ENV_BUFFER + 300 <= STAGE9_SCRATCH + STAGE9_SCRATCH_CAPACITY
	ASSERT STAGE9_SCRATCH + STAGE9_SCRATCH_CAPACITY <= PAGE_BASE + 0x4000
	IFNDEF STAGE10_PAGE_LAYOUT
	ASSERT S9_TFTP_LOCAL_NAME + 96 < STACK_TOP
	ENDIF

	IFDEF STAGE10_PAGE_LAYOUT
DNS_QUERY_DESC		EQU PAGE_BASE + 0x3600 ; 10 bytes
DNS_PARSE_DESC		EQU PAGE_BASE + 0x3610 ; 10 bytes
DNS_TRANSACTION_ID	EQU PAGE_BASE + 0x3620 ; word, host order
DNS_USED_SERVER	EQU PAGE_BASE + 0x3622 ; four bytes
DNS_EXPLICIT_SERVER	EQU PAGE_BASE + 0x3626 ; four bytes
DNS_RESULT_IP		EQU PAGE_BASE + 0x362A ; four bytes
DNS_ATTEMPTS		EQU PAGE_BASE + 0x362E
DNS_SERVER_INDEX	EQU PAGE_BASE + 0x362F
DNS_EXPLICIT_FLAG	EQU PAGE_BASE + 0x3630
DNS_LAST_ERROR		EQU PAGE_BASE + 0x3631
S10_APP_PORT		EQU PAGE_BASE + 0x3632 ; caller port preserved across resolver UDP state
DNS_NAME_POINTER	EQU PAGE_BASE + 0x3634 ; word

NTP_BUILD_DESC		EQU PAGE_BASE + 0x3640 ; 8 bytes
NTP_PARSE_DESC		EQU PAGE_BASE + 0x3650 ; 10 bytes
NTP_COOKIE		EQU PAGE_BASE + 0x3660 ; eight bytes
NTP_SECONDS		EQU PAGE_BASE + 0x3668 ; four bytes, little endian
NTP_DAYS		EQU PAGE_BASE + 0x366C ; word since 1970-01-01
NTP_YEAR		EQU PAGE_BASE + 0x366E ; word
NTP_MONTH		EQU PAGE_BASE + 0x3670
NTP_DAY			EQU PAGE_BASE + 0x3671
NTP_HOUR		EQU PAGE_BASE + 0x3672
NTP_MINUTE		EQU PAGE_BASE + 0x3673
NTP_SECOND		EQU PAGE_BASE + 0x3674
NTP_TZ_MINUTES		EQU PAGE_BASE + 0x3675 ; signed word
NTP_TARGET_DEFAULT	EQU PAGE_BASE + 0x3677
NTP_ATTEMPTS		EQU PAGE_BASE + 0x3678

S10_PAGE_COMMAND_BUFFER EQU PAGE_BASE + 0x3E00 ; command after WIN1 remapping
	IFDEF STAGE12_LAYOUT
; Stage 12 loads at 4080h, so the 256 bytes at 4000h..40FFh -- the space below
; the load address plus the header the loader has already consumed -- are the
; only storage that is neither the claimed page nor code. The command record is
; copied there before WIN2 is claimed, and the exit code is read from there
; after the page is released. It is 16 KiB away from every stack.
S10_COMMAND_BUFFER	EQU 0x4000
; Entry/bootstrap stack: the top of WIN2. In the standard DSS layout the
; program owns WIN1+WIN2 as one contiguous 0x4100..0xBFFF region, so this is
; already the program's RAM when the loader installs the stack -- far above the
; image and outside WIN1, which is what makes it safe from both the loader and
; the BIOS WIN_MOVE remap.
S10_STACK_TOP		EQU 0xBFF0
S10_BOOTSTRAP_STACK	EQU S10_STACK_TOP
	ELSE
S10_COMMAND_BUFFER	EQU 0xBF00 ; bootstrap copy before WIN1 remapping
S10_STACK_TOP		EQU 0xBEF0 ; bootstrap/header stack and linked-code limit
S10_BOOTSTRAP_STACK	EQU S10_STACK_TOP
	ENDIF
	IFDEF STAGE12_LAYOUT
; The entry stack no longer sits just above the image, so it no longer bounds
; it; PAGE_BASE does (see the ASSERT at the end of wget.asm). This is only the
; slack the loader and one interrupt frame need under S10_STACK_TOP.
S10_BOOTSTRAP_STACK_RESERVE EQU 0x0010
	ELSE
; DSS installs the header stack before the entry point runs and executes the
; loader and the interrupt handlers on it, so an image ending just under it
; gets its last routine overwritten -- silently, and only where that routine is
; reached. This is the same 64-byte gap the EXE harness enforces at load time;
; keeping the two equal makes the assembler, not a test run, the thing that
; catches an image growing into its own stack.
S10_BOOTSTRAP_STACK_RESERVE EQU 0x0040
	ENDIF
; Neither variant may put the runtime stack in WIN1: BIOS WIN_MOVE maps the
; video page over WIN1 on every scrolled console line and restores SLOT1 from a
; POP taken while that page is still mapped, so a WIN1 stack does not survive
; the first scrolled line. Stage 12 uses the top of its claimed WIN2 page; the
; others keep theirs in resident WIN2 just below the ISA window.
	IFDEF STAGE12_LAYOUT
S10_RUNTIME_STACK_TOP	EQU PAGE_BASE + 0x3FF0
	ELSE
S10_RUNTIME_STACK_TOP	EQU 0xC000
	ENDIF
	ASSERT S10_RUNTIME_STACK_TOP > 0x7FFF	; never in WIN1, see WIN_MOVE above
	IFNDEF STAGE12_LAYOUT
	ASSERT S10_STACK_TOP <= S9_EXIT_CODE
	ASSERT NETDRV_FAIL_CODE < S10_COMMAND_BUFFER
	ENDIF
	ASSERT STAGE9_SCRATCH + STAGE9_SCRATCH_CAPACITY <= S10_PAGE_COMMAND_BUFFER
	ASSERT S10_PAGE_COMMAND_BUFFER + 0x0100 <= S10_RUNTIME_STACK_TOP
	ENDIF

	IFDEF STAGE11_LAYOUT
; Stage 11 reuses the Stage 9 packet buffers and dedicates the remaining DSS
; page space to an application stream buffer, two honest one-MSS receive
; queues and two independent TCP contexts.
	IFDEF STAGE13_LAYOUT
; FTP keeps both channels open at once (control + data), so unlike WGET it
; needs two real pending regions and two real contexts, each as deep as
; WGET's single one (the deep receive window is keyed off STAGE12_LAYOUT,
; which FTP also defines, and applies to both channels; only the
; single-context restriction is keyed off TCPX_SINGLE_CONTEXT, which FTP
; opts out of -- see tcp_transport.asm). Packed flush against RUNTIME_BASE
; with no slack, so
; NETDRV_FAIL_CODE/S9_EXIT_CODE above are carved out of F13_STATE_BASE's own
; reserve instead of a gap in this block.
	IFDEF TCPX_LARGE_MSS
; At MSS 1460 the data channel's durable queue is two whole segments (2,920)
; and the control channel's is one (TCPX_SPLIT_PENDING, tcp_transport.asm).
; The asymmetry is the whole point: the control channel only ever queues the
; one reply line that lands while the data channel is being drained -- a
; "226 Transfer complete" -- so a second 2,920-byte region was 1.4 KiB of
; this page held for a few dozen bytes, and this page is the only place the
; disk buffer can come from. The application buffer then takes what is left
; below RUNTIME_BASE: it stages one control reply or one LIST chunk at a
; time and both are read in a loop, so shrinking it costs extra RECV calls
; on paths that are not the transfer.
; Region 0 belongs to FTP's control channel and region 1 to its data channel
; (FTP_CTRL_CHANNEL/FTP_DATA_CHANNEL in ftp.asm), which is why the deep one
; is the second.
S11_PENDING0		EQU PAGE_BASE + 0x1C00
S11_PENDING_CAPACITY	EQU 0x05B4	; 1 * 1460, control channel
S11_PENDING1_CAPACITY	EQU 0x0B68	; 2 * 1460, data channel
S11_APP_CAPACITY	EQU 0x0194
	ELSE
S11_PENDING0		EQU PAGE_BASE + 0x1800
S11_PENDING_CAPACITY	EQU 0x0A78	; TCP_RECV_SEGMENTS * TCP_MSS; see tcp_transport.asm's ASSERT
S11_PENDING1_CAPACITY	EQU 0x0A78
S11_APP_CAPACITY	EQU 0x01C0	; flush: S11_APP_BUFFER + S11_APP_CAPACITY = RUNTIME_BASE exactly
	ENDIF
S11_PENDING1		EQU S11_PENDING0 + S11_PENDING_CAPACITY
S11_CONTEXT0		EQU S11_PENDING1 + S11_PENDING1_CAPACITY
S11_CONTEXT1		EQU S11_CONTEXT0 + S11_CONTEXT_SIZE
S11_STATE_BASE		EQU S11_CONTEXT1 + S11_CONTEXT_SIZE
S11_APP_BUFFER		EQU S11_STATE_BASE + 0x0100
	ELSE
	IFDEF STAGE12_LAYOUT
; WGET's channel never selects context 1 (see SELECT_CONTEXT's
; STAGE12_LAYOUT branch), so the second one-MSS queue and context that the
; two-channel layout below reserves are folded back into one pending region
; sized for the full TCP_RECV_WINDOW (tcp.inc) instead of a single MSS.
; The region starts where the disk buffer used to end: two of its eight KiB pay
; for a receive window the peer can actually keep segments in flight against,
; which is worth far more than the larger write batches. Everything above
; S11_CONTEXT0 is unchanged.
S11_PENDING0		EQU PAGE_BASE + 0x2000
S11_PENDING1		EQU S11_PENDING0	; PENDING_BASE's IX==CONTEXT0 branch always
						; fires under STAGE12_LAYOUT; this alias only
						; keeps the shared unconditional code assembling
	IFDEF TCPX_LARGE_MSS
S11_PENDING_CAPACITY	EQU 0x0B68	; 2 * 1460; see tcp_transport.asm's ASSERT
	ELSE
S11_PENDING_CAPACITY	EQU 0x0A78	; TCP_RECV_SEGMENTS * TCP_MSS; see tcp_transport.asm's ASSERT
	ENDIF
S11_CONTEXT0		EQU PAGE_BASE + 0x2C40
S11_STATE_BASE		EQU PAGE_BASE + 0x2C80
S11_APP_BUFFER		EQU PAGE_BASE + 0x2D80
S11_APP_CAPACITY	EQU 0x0220
	ELSE
S11_APP_BUFFER		EQU PAGE_BASE + 0x1000
S11_APP_CAPACITY	EQU 0x1000
S11_PENDING0		EQU PAGE_BASE + 0x2000
S11_PENDING1		EQU PAGE_BASE + 0x2220
S11_PENDING_CAPACITY	EQU 0x0218
S11_CONTEXT0		EQU PAGE_BASE + 0x2500
S11_CONTEXT1		EQU PAGE_BASE + 0x2540
S11_STATE_BASE		EQU PAGE_BASE + 0x2600
	ENDIF
	ENDIF
S11_CONTEXT_SIZE	EQU 40
S11_TCP_BUILD_DESC	EQU S11_STATE_BASE + 0x00
; Send burst (tcp_transport.asm's CHOOSE_BURST/SEND_BURST, TCPX_SEND_BURST
; builds only). The build descriptor above is TCPB_DESC_LENGTH = 23 bytes long
; and is padded to 32, so these live in its tail rather than past
; S11_WAIT_PROGRESS, where the block is already flush against F13_STATE_BASE.
; BURST_SEQ is the second segment's sequence number, kept as its own four bytes
; because S11_TARGET_ACK is simultaneously holding the burst's end. A pair is
; always two whole segments, so the second one needs no length of its own.
S11_BURST_SEQ		EQU S11_STATE_BASE + 0x17 ; four bytes, network order
S11_BURST_FIRST		EQU S11_STATE_BASE + 0x1B ; word, first segment's length
S11_BURST_PAIR		EQU S11_STATE_BASE + 0x1D ; non-zero: a second segment
						; of one whole MSS follows
	ASSERT S11_BURST_SEQ >= S11_TCP_BUILD_DESC + 23	; TCPB_DESC_LENGTH, spelled
							; out because tcp.inc is
							; included after this file
	ASSERT S11_BURST_PAIR + 1 <= S11_STATE_BASE + 0x20
S11_TCP_PARSE_DESC	EQU S11_STATE_BASE + 0x20
S11_PARSE_SEQUENCE	EQU S11_STATE_BASE + 0x40
S11_PARSE_ACK		EQU S11_STATE_BASE + 0x44
S11_SELECTED_CONTEXT	EQU S11_STATE_BASE + 0x48 ; word
S11_MATCH_CONTEXT	EQU S11_STATE_BASE + 0x4A ; word
S11_SEND_POINTER	EQU S11_STATE_BASE + 0x4C ; word
S11_SEND_REMAINING	EQU S11_STATE_BASE + 0x4E ; word
S11_SEND_CONFIRMED	EQU S11_STATE_BASE + 0x50 ; word
S11_SEGMENT_LENGTH	EQU S11_STATE_BASE + 0x52 ; word
S11_TARGET_ACK		EQU S11_STATE_BASE + 0x54 ; four bytes, network order
S11_FRAME_LENGTH	EQU S11_STATE_BASE + 0x58 ; word
S11_TCP_LENGTH		EQU S11_STATE_BASE + 0x5A ; word
S11_IP_ID		EQU S11_STATE_BASE + 0x5C ; word
S11_SEGMENT_ACCEPTED	EQU S11_STATE_BASE + 0x5F
S11_CHANNEL		EQU S11_STATE_BASE + 0x60
S11_COPY_LENGTH		EQU S11_STATE_BASE + 0x61 ; word
S11_BUILD_FLAGS	EQU S11_STATE_BASE + 0x63
S11_WAIT_MASK		EQU S11_STATE_BASE + 0x64
S11_ACTIVE_LENGTH	EQU S11_STATE_BASE + 0x65 ; word, survives nested ACKs
S11_TIMEOUT_MS		EQU S11_STATE_BASE + 0x67 ; word, RECV call deadline
S11_DIAG_STAGE		EQU S11_STATE_BASE + 0x69
S11_SEQUENCE_OVERRIDE	EQU S11_STATE_BASE + 0x6A
S11_NEXT_LOCAL_PORT	EQU S11_STATE_BASE + 0x6B ; 49152..65535
S11_WAIT_ALL		EQU S11_STATE_BASE + 0x6D
; Set by HANDLE_SEGMENT (round-2 throughput: driver primitives must not be
; called from inside PROCESS_FRAME/HANDLE_SEGMENT's own call chain, so the
; ACK a segment earns is deferred and sent from .WAIT_LOOP once PROCESS_FRAME
; has returned) instead of sending immediately from .ACK_CURRENT. Reset at
; HANDLE_SEGMENT entry and again once .WAIT_LOOP has consumed it, so a frame
; that never reaches .ACK_CURRENT (ARP, an ignored segment) cannot replay a
; stale send. The context to send it on is S11_MATCH_CONTEXT, still valid:
; nothing overwrites it between HANDLE_SEGMENT setting this flag and
; .WAIT_LOOP consuming it one frame later.
S11_ACK_NOW		EQU S11_STATE_BASE + 0x6E
; Directly-delivered segments acknowledged in one go (TCP_ACK_EVERY): counted
; up by .SESSION_FAST and cleared by SEND_OWED_ACK, which sends whenever
; either this or S11_ACK_NOW is set. Kept apart from S11_ACK_NOW precisely
; because HANDLE_SEGMENT clears that one at entry -- a slow-path frame
; arriving mid-drain must not swallow a debt the fast path still owes.
S11_ACK_OWED		EQU S11_STATE_BASE + 0x6F
S11_IPV4_BUILD_DESC	EQU S11_STATE_BASE + 0x70
S11_IPV4_PARSE_DESC	EQU S11_STATE_BASE + 0x80 ; IP4P_DESC_LENGTH = 18 bytes
; Two-phase receive (tcp_transport.asm's FAST_RECEIVE): the payload length the
; predicate accepted, and how many segments the fused checksum rejected. These
; sit in the gap between the parse descriptor above and W12_/F13_STATE_BASE at
; S11_STATE_BASE+0xA0, which is the only slack the state block still has.
S11_FAST_LENGTH		EQU S11_STATE_BASE + 0x92 ; word
S11_FAST_BADSUM		EQU S11_STATE_BASE + 0x94 ; word, diagnostic counter
; Direct-delivery window. RECV opens it around its own WAIT_FOR_EVENT and
; closes it again the moment that call returns, so it is non-zero only while a
; RECV is genuinely waiting with room in the caller's buffer: everywhere else
; (SEND, CLOSE, OPEN, the handshake) S11_RX_FREE is zero and FAST_RECEIVE
; falls back to the pending slot. RESET clears it.
S11_RX_DEST		EQU S11_STATE_BASE + 0x96 ; word, caller's buffer
S11_RX_FREE		EQU S11_STATE_BASE + 0x98 ; word, its capacity, 0 = closed
S11_RX_DELIVERED	EQU S11_STATE_BASE + 0x9A ; word, written into it so far
S11_FAST_DEST		EQU S11_STATE_BASE + 0x9C ; word, this segment's target
S11_FAST_DIRECT		EQU S11_STATE_BASE + 0x9E ; non-zero: target is the caller
S11_WAIT_PROGRESS	EQU S11_STATE_BASE + 0x9F ; polls that found a frame and
					; so skipped NETTIME.TICK, counting down
	ASSERT S11_WAIT_PROGRESS + 1 <= S11_STATE_BASE + 0xA0
S11_REMOTE_TEXT		EQU PAGE_BASE + 0x3700

	IFDEF STAGE13_LAYOUT
	ASSERT S11_PENDING0 + S11_PENDING_CAPACITY <= S11_PENDING1
	ASSERT S11_PENDING1 + S11_PENDING1_CAPACITY <= S11_CONTEXT0
	ASSERT S11_CONTEXT0 + S11_CONTEXT_SIZE <= S11_CONTEXT1
	ASSERT S11_CONTEXT1 + S11_CONTEXT_SIZE <= S11_STATE_BASE
	ASSERT S11_STATE_BASE + 0x0100 <= S11_APP_BUFFER
	ASSERT S11_APP_BUFFER + S11_APP_CAPACITY <= RUNTIME_BASE
	ELSE
	IFNDEF STAGE12_LAYOUT
	ASSERT S11_APP_BUFFER + S11_APP_CAPACITY <= S11_PENDING0
	ASSERT S11_PENDING0 + S11_PENDING_CAPACITY <= S11_PENDING1
	ASSERT S11_PENDING1 + S11_PENDING_CAPACITY <= S11_CONTEXT0
	ASSERT S11_CONTEXT0 + S11_CONTEXT_SIZE <= S11_CONTEXT1
	ASSERT S11_CONTEXT1 + S11_CONTEXT_SIZE <= S11_STATE_BASE
	ELSE
	ASSERT S11_PENDING0 + S11_PENDING_CAPACITY <= S11_CONTEXT0
	ASSERT S11_CONTEXT0 + S11_CONTEXT_SIZE <= S11_STATE_BASE
	ENDIF
	ENDIF
	ASSERT S11_STATE_BASE + 0x0100 <= S11_REMOTE_TEXT

	IFDEF STAGE13_LAYOUT
; FTP state, laid out the same way WGET's W12 block is: scalars reuse the
; slack past S11's own field high-water mark inside S11_STATE_BASE's 0x100
; reserve, and the two page-backed status bytes NETDRV_FAIL_CODE/S9_EXIT_CODE
; (memory.inc, above) are carved out of the tail of that same reserve since,
; unlike WGET's single-context layout, this one packs flush with no spare
; gap of its own. Strings start right after S11_REMOTE_TEXT, same as W12's.
F13_STATE_BASE		EQU S11_STATE_BASE + 0xA0
; FLAGS bits: 0 force(-y/-f), 1 resume(-r), 2 dots(-d), 3 list(-l and -n),
; 4 request NLST (-n), 5 has -o, 6 has -u, 7 has -p. PUT is not a flag: it
; sets F13_MODE.
F13_FLAGS		EQU F13_STATE_BASE + 0x00
F13_FLAG_LIST_MASK	EQU 0x08
F13_FLAG_NLST_BIT	EQU 4
F13_FLAG_NLST_MASK	EQU 0x10
F13_MODE		EQU F13_STATE_BASE + 0x01	; 0 GET, 1 PUT, 2 LIST -- decided post-parse
F13_CTRL_PORT		EQU F13_STATE_BASE + 0x02 ; word, host order, default 21
F13_REPLY_CODE		EQU F13_STATE_BASE + 0x04 ; three ASCII digits, not NUL-terminated
F13_ACCUM_LEN		EQU F13_STATE_BASE + 0x07 ; word, bytes buffered in F13_ACCUM_BUF
F13_LINE_LEN		EQU F13_STATE_BASE + 0x09 ; word, length of the extracted reply line
F13_DATA_PORT		EQU F13_STATE_BASE + 0x0B ; word, host order, from PASV
F13_DATA_IP		EQU F13_STATE_BASE + 0x0D ; four bytes, network order
F13_TOTAL_SIZE		EQU F13_STATE_BASE + 0x11 ; four bytes LE, from SIZE/local seek
F13_TOTAL_KNOWN	EQU F13_STATE_BASE + 0x15
F13_TRANSFERRED	EQU F13_STATE_BASE + 0x16 ; four bytes LE, this session's bytes
F13_RESUME_OFFSET	EQU F13_STATE_BASE + 0x1A ; four bytes LE
F13_START_TIME		EQU F13_STATE_BASE + 0x1E ; three-byte seconds-of-day
F13_FILE_HANDLE	EQU F13_STATE_BASE + 0x24
F13_FILE_OPEN		EQU F13_STATE_BASE + 0x25
F13_PROGRESS_COUNT	EQU F13_STATE_BASE + 0x26
F13_LAST_ERROR		EQU F13_STATE_BASE + 0x27
F13_RESUME_SELECTED	EQU F13_STATE_BASE + 0x28
F13_WORK32		EQU F13_STATE_BASE + 0x29 ; four bytes, decimal math scratch
F13_NUMBER_BUFFER	EQU F13_STATE_BASE + 0x2D ; eleven bytes
F13_POS_COUNT		EQU F13_STATE_BASE + 0x38 ; PARSE_FTP's positional-argument cursor
F13_LOCAL_ARG_PTR	EQU F13_STATE_BASE + 0x39 ; word, resolved local file path
F13_REMOTE_ARG_PTR	EQU F13_STATE_BASE + 0x3B ; word, resolved RETR/STOR/LIST argument
F13_BUFFER_USED	EQU F13_STATE_BASE + 0x3D ; word, bytes staged in STAGE9_FILE_BUFFER
; F13_STATE_BASE+0x3F/+0x40 is free (GET_LOOP's direct RECV into
; STAGE9_FILE_BUFFER retired the APPEND_DATA cursor that lived here).
F13_CHUNK_LEN		EQU F13_STATE_BASE + 0x41 ; word, PUT_LOOP's staged send length
F13_TOTAL_WRITTEN	EQU F13_STATE_BASE + 0x43 ; four bytes LE, progress display only
; Elapsed seconds is a three-byte quantity given a four-byte cell so that both
; readers can take it as one 32-bit load: nothing writes +3 and the page is
; cleared at startup, so the top byte is structurally zero.
F13_ELAPSED		EQU F13_STATE_BASE + 0x47 ; four bytes LE, seconds
; F13_STATE_BASE+0x4B .. +0x5D remains free for further scalars. The last two
; bytes of the reserve are the page-backed status pair every STAGE10_PAGE
; layout needs somewhere; they are written here, relative to the reserve, so
; that moving the S11 block moves them with it. Spelling them as an absolute
; PAGE_BASE offset (which is what the two IFDEFs near the top of this file
; used to do) survived the MSS change as a still-assembling address that had
; drifted 542 bytes into S11_APP_BUFFER -- onto bytes a long LIST or a long
; control reply writes.
NETDRV_FAIL_CODE	EQU F13_STATE_BASE + 0x5E
S9_EXIT_CODE		EQU F13_STATE_BASE + 0x5F
F13_HOST		EQU PAGE_BASE + 0x3800 ; 64 bytes
F13_REMOTE_PATH	EQU PAGE_BASE + 0x3840 ; 256 bytes, RETR/STOR/LIST argument
F13_LOCAL_OUTPUT	EQU PAGE_BASE + 0x3940 ; 96 bytes
F13_ACCUM_BUF		EQU PAGE_BASE + 0x39A0 ; 512 bytes, control-reply accumulator
F13_REPLY_LINE		EQU PAGE_BASE + 0x3BA0 ; 256 bytes, one extracted reply line
F13_SAVED_CWD		EQU PAGE_BASE + 0x3CA0 ; 256 bytes; file.asm's FILE_SAVED_CWD
F13_DIR_BUFFER		EQU PAGE_BASE + 0x3DA0 ; 96 bytes; file.asm's FILE_DIR_BUFFER
; The last three fields deliberately reuse the page's command-record range
; (F13_USER == S10_PAGE_COMMAND_BUFFER; the ASSERT below pins that). Nothing
; else fits below 3E00h, and the page copy is redundant here: ALLOCATE_FRESH
; leaves FTP's IX on the WIN1 copy at S10_COMMAND_BUFFER precisely because
; PARSE_FTP writes -u/-p/-o into these three while it is still tokenising the
; command line, which would otherwise overwrite its own unparsed tail.
F13_USER		EQU PAGE_BASE + 0x3E00 ; 32 bytes, -u (default "anonymous")
F13_PASS		EQU PAGE_BASE + 0x3E20 ; 32 bytes, -p (default "anonymous@")
; -o's raw text needs its own storage: F13_REPLY_LINE looked "dead until the
; control dialog starts" when this was first written, but DERIVE_ARGS only
; stores a pointer to it, and every reply the control dialog reads (220,
; USER, PASS, TYPE, SIZE, PASV) overwrites F13_REPLY_LINE before that pointer
; is ever dereferenced -- so -o silently renamed to the last reply's text.
F13_OUTPUT_OVERRIDE	EQU PAGE_BASE + 0x3E40 ; 96 bytes, -o (GET local / PUT remote)
F13_URL			EQU S11_REMOTE_TEXT ; 256 bytes, resolver input
; file.asm's OPEN_OUTPUT_ORC/OPEN_APPEND (shared with WGET) are written
; against the W12_* names; alias them so FTP's RETR resume uses the same
; code unmodified.
W12_RESUME_OFFSET	EQU F13_RESUME_OFFSET
W12_RESUME_SELECTED	EQU F13_RESUME_SELECTED
W12_FILE_HANDLE	EQU F13_FILE_HANDLE

	ASSERT STAGE9_FILE_BUFFER + STAGE9_FILE_CAPACITY <= S11_PENDING0
	ASSERT S11_IPV4_PARSE_DESC + 18 <= F13_STATE_BASE
	ASSERT F13_STATE_BASE + 0x60 <= S11_APP_BUFFER
	ASSERT S9_ENV_BUFFER + 300 <= S11_REMOTE_TEXT
	ASSERT F13_HOST + 64 <= F13_REMOTE_PATH
	ASSERT F13_REMOTE_PATH + 256 <= F13_LOCAL_OUTPUT
	ASSERT F13_LOCAL_OUTPUT + 96 <= F13_ACCUM_BUF
	ASSERT F13_ACCUM_BUF + 512 <= F13_REPLY_LINE
	ASSERT F13_REPLY_LINE + 256 <= F13_SAVED_CWD
	ASSERT F13_SAVED_CWD + 256 <= F13_DIR_BUFFER
	ASSERT F13_DIR_BUFFER + 96 <= F13_USER
	ASSERT F13_USER + 32 <= F13_PASS
	ASSERT F13_PASS + 32 <= F13_OUTPUT_OVERRIDE
	ASSERT F13_OUTPUT_OVERRIDE + 96 <= S10_RUNTIME_STACK_TOP - 0x0100
	ASSERT F13_USER == S10_PAGE_COMMAND_BUFFER ; see the note above the block
	ELSE
	IFDEF STAGE12_LAYOUT
; HTTP/WGET state lives in regions unused by the TFTP application. The DNS
; descriptors at 7600h remain intact and can be reused on every redirect.
W12_STATE_BASE		EQU S11_STATE_BASE + 0xA0
W12_FLAGS		EQU W12_STATE_BASE + 0x00
W12_REDIRECTS		EQU W12_STATE_BASE + 0x01
W12_HTTP_STATE		EQU W12_STATE_BASE + 0x02
W12_STATUS		EQU W12_STATE_BASE + 0x03 ; word
W12_HEADER_LENGTH	EQU W12_STATE_BASE + 0x05
W12_HEADER_OVERFLOW	EQU W12_STATE_BASE + 0x06
W12_CONTENT_KNOWN	EQU W12_STATE_BASE + 0x07
W12_FILE_OPEN		EQU W12_STATE_BASE + 0x08
W12_FILE_HANDLE		EQU W12_STATE_BASE + 0x09
W12_BUFFER_USED		EQU W12_STATE_BASE + 0x0A ; word
W12_CONTENT_LENGTH	EQU W12_STATE_BASE + 0x0C ; four bytes LE
W12_BODY_RECEIVED	EQU W12_STATE_BASE + 0x10 ; four bytes LE
W12_TOTAL_WRITTEN	EQU W12_STATE_BASE + 0x14 ; four bytes LE
W12_RESUME_OFFSET	EQU W12_STATE_BASE + 0x18 ; four bytes LE
W12_START_TIME		EQU W12_STATE_BASE + 0x1C ; three-byte seconds-of-day
W12_ELAPSED		EQU W12_STATE_BASE + 0x1F ; three bytes
W12_LOCATION_SEEN	EQU W12_STATE_BASE + 0x22
W12_HEADER_BYTES	EQU W12_STATE_BASE + 0x23 ; word
W12_PORT		EQU W12_STATE_BASE + 0x25 ; word
W12_WORK32		EQU W12_STATE_BASE + 0x27 ; four bytes
W12_NUMBER_BUFFER	EQU W12_STATE_BASE + 0x2B ; eleven bytes
W12_REQUEST_LENGTH	EQU W12_STATE_BASE + 0x36 ; word
W12_LAST_ERROR		EQU W12_STATE_BASE + 0x38
W12_HOP_DONE		EQU W12_STATE_BASE + 0x39
W12_PROGRESS_COUNT	EQU W12_STATE_BASE + 0x3A
W12_OUTPUT_PTR		EQU W12_STATE_BASE + 0x3B ; word
W12_STATUS_SEEN		EQU W12_STATE_BASE + 0x3D
W12_RESUME_SELECTED	EQU W12_STATE_BASE + 0x3E
W12_HOST		EQU PAGE_BASE + 0x3800 ; 64 bytes
W12_PATH		EQU PAGE_BASE + 0x3840 ; 256 bytes
W12_OUTPUT		EQU PAGE_BASE + 0x3940 ; 96 bytes
W12_HEADER_LINE		EQU PAGE_BASE + 0x39A0 ; 256 bytes
W12_OUTPUT_SNAPSHOT	EQU PAGE_BASE + 0x3AA0 ; 96 bytes, stable across redirects
W12_URL			EQU S11_REMOTE_TEXT ; 256 bytes

	ASSERT STAGE9_FILE_BUFFER + STAGE9_FILE_CAPACITY <= S11_PENDING0
	ASSERT S11_STATE_BASE + 0x0100 <= S11_APP_BUFFER
	ASSERT S11_APP_BUFFER + S11_APP_CAPACITY <= RUNTIME_BASE
	ASSERT S11_IPV4_PARSE_DESC + 18 <= W12_STATE_BASE
	ASSERT W12_STATE_BASE + 0x40 <= S11_APP_BUFFER
	ASSERT W12_HOST + 64 <= W12_PATH
	ASSERT W12_PATH + 256 <= W12_OUTPUT
	ASSERT W12_OUTPUT + 96 <= W12_HEADER_LINE
	ASSERT W12_HEADER_LINE + 256 <= W12_OUTPUT_SNAPSHOT
	ASSERT W12_OUTPUT_SNAPSHOT + 96 <= S9_ENV_BUFFER
	ASSERT W12_URL + 256 <= STAGE9_SCRATCH
	ASSERT S9_TFTP_ERROR_DESC + 10 <= S10_RUNTIME_STACK_TOP - 0x0100
	ENDIF
	ENDIF
	ENDIF
	ENDIF

PING_FLAG_INFINITE	EQU 0x01

STAGE8_TX_BUFFER	EQU STAGE7_TX_BUFFER
STAGE8_TX_CAPACITY	EQU STAGE7_TX_CAPACITY
STAGE8_RX_BUFFER	EQU STAGE7_RX_BUFFER
STAGE8_RX_CAPACITY	EQU STAGE7_RX_CAPACITY
STAGE8_MAX_FRAME	EQU 14 + 20 + 8 + 1472

	ASSERT STAGE8_MAX_FRAME <= 1514
	ASSERT STAGE8_MAX_FRAME <= STAGE8_TX_CAPACITY
	ASSERT STAGE8_TX_BUFFER + STAGE8_TX_CAPACITY <= STAGE8_RX_BUFFER
	ASSERT STAGE8_RX_BUFFER + STAGE8_RX_CAPACITY <= PAGE_BASE + 0x4000

; NETCFG uses the unused resident range plus one mapped page. Values are
; parsed completely before ENV_SET starts, making parse errors transactional.
NETCFG_FLAGS		EQU RUNTIME_BASE + 0x300
NETCFG_VERBOSE		EQU RUNTIME_BASE + 0x301
NETCFG_SEEN		EQU RUNTIME_BASE + 0x302 ; word known-key bitmap
NETCFG_WARNINGS		EQU RUNTIME_BASE + 0x304
NETCFG_FILE_HANDLE	EQU RUNTIME_BASE + 0x305
NETCFG_FILE_LENGTH	EQU RUNTIME_BASE + 0x306 ; word
NETCFG_VALUES		EQU RUNTIME_BASE + 0x360 ; normalized value table
NETCFG_SCRATCH		EQU RUNTIME_BASE + 0x420

STAGE7_TX_BUFFER	EQU PAGE_BASE + 0x0000
STAGE7_TX_CAPACITY	EQU 0x0800
STAGE7_RX_BUFFER	EQU PAGE_BASE + 0x0800
STAGE7_RX_CAPACITY	EQU 0x0800
NETCFG_PATH		EQU STAGE7_RX_BUFFER ; APPINFO may return a 256-byte path

	ASSERT STAGE7_TX_BUFFER + STAGE7_TX_CAPACITY <= STAGE7_RX_BUFFER
	ASSERT STAGE7_RX_BUFFER + STAGE7_RX_CAPACITY <= PAGE_BASE + 0x4000
	; Page-backed state must stay under the stack that shares its window. For
	; Stage 12 that is the claimed page's own stack, not the entry stack.
	IFDEF STAGE12_LAYOUT
	ASSERT NETCFG_SCRATCH + 0x0200 < S10_RUNTIME_STACK_TOP
	ASSERT NETTIME_ELAPSED_MS + 2 < S10_RUNTIME_STACK_TOP
	ELSE
	ASSERT NETCFG_SCRATCH + 0x0200 < STACK_TOP
	ASSERT NETTIME_ELAPSED_MS + 2 < STACK_TOP
	ENDIF

EEPROM_BUFFER		EQU RUNTIME_BASE + 0x100 ; 128 bytes, words 00..3F
PROBE_ROW		EQU RUNTIME_BASE + 0x180 ; 16 bytes
	IFDEF STAGE10_PAGE_LAYOUT
STACK_TOP		EQU S10_STACK_TOP
	ELSE
STACK_TOP		EQU 0xBFF0
	ENDIF

	ENDIF	; UNET_DLL

	ENDIF
