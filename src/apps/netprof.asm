; NETPROF.EXE - where the seconds go during network bring-up.
; SPDX-License-Identifier: BSD-3-Clause
;
; Developer tool, IMG only. It runs the sequence every network utility runs
; between printing its banner and getting its first answer off the wire, and
; reports how many whole RTC seconds each stage cost. It exists because on
; real hardware PING/FTP/WGET all paused several seconds before doing any
; visible work and nothing in the shipped output said which stage was
; responsible. Its first run answered that: on a real Sprinter P1..P4 are all
; zero seconds, which is why P5/P6 -- the first frames on the wire -- were
; added afterwards.
;
; DISCOVER is additionally timed on its own before the driver comes up, so
; the 64-word EEPROM read can be separated from ACTIVATE and INIT inside the
; one NETDRV.INIT call the utilities actually make: INIT minus DISCOVER is
; P3 minus P2.

EXE_VERSION	EQU 1
	DEFINE RUNTIME_BASE 0x7000
	DEFINE EL3_ATTACH_PROBE		; enables -n; see el3.asm DISCOVER
	DEFINE STAGE9_LAYOUT
	DEFINE STAGE10_PAGE_LAYOUT
	DEFINE STAGE10_DNS

	DEVICE NOSLOT64K
	INCLUDE "version.inc"
	INCLUDE "dss.inc"
	INCLUDE "macro.inc"
	INCLUDE "memory.inc"
	INCLUDE "el3.inc"
	INCLUDE "netdrv.inc"
	INCLUDE "netcfg.inc"
	INCLUDE "ip_icmp.inc"
	INCLUDE "udp_tftp.inc"
	INCLUDE "dns_ntp.inc"

	MODULE MAIN

	ORG 0x8080
	DB "EXE",EXE_VERSION
	DW 0x0080,0,0,0,0,0
	DW START,START,STACK_TOP
	DS 106,0

	ORG 0x8100
START
	LD	SP,STACK_TOP
	CALL	@S10APP.SAVE_COMMAND
	CALL	@S10APP.ALLOCATE_FRESH
	JP	C,BOOT_FAIL
	LD	SP,S10_RUNTIME_STACK_TOP
	LD	(CMDLINE_SOURCE),IX
	CALL	SCAN_NO_RESET
	CALL	@ARP.CLEAR_CACHE
	LD	HL,MSG_BANNER
	CALL	@CONSOLE.LINE

	; The clock is read once here and once per stage boundary, so the first
	; reading also absorbs whatever the banner cost.
	CALL	MARK
	CALL	@S9APP.LOAD_ACTIVE_CONFIG
	JP	C,CONFIG_FAIL
	LD	HL,MSG_P1
	CALL	REPORT_LINE

	; DISCOVER timed on its own, before the driver comes up: it resets the
	; adapter and re-reads all 64 EEPROM words, the one part of NETDRV.INIT
	; with a documented per-word wait. It runs first because it leaves the
	; card in the ID state, which is exactly what NETDRV.INIT expects to
	; find; running it afterwards would deactivate a working card.
	CALL	MARK
	XOR	A
	CALL	TRY_DISCOVER
	JR	NC,.EEPROM_DONE
	LD	A,1
	CALL	TRY_DISCOVER
	JR	NC,.EEPROM_DONE
	LD	A,0xFF
	LD	(NP_SLOT),A
.EEPROM_DONE
	LD	HL,MSG_P2
	CALL	REPORT_LINE
	LD	HL,MSG_SLOT
	CALL	@CONSOLE.STRING
	LD	A,(NP_SLOT)
	CALL	@CONSOLE.DEC8
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	A,(@EL3.SKIP_GLOBAL_RESET)
	OR	A
	JR	Z,.RESET_DONE
	LD	HL,MSG_NORESET
	CALL	@CONSOLE.LINE
.RESET_DONE

	CALL	@S9APP.INIT_DRIVER
	JP	C,HARDWARE_FAIL
	LD	HL,MSG_P3
	CALL	REPORT_LINE

	LD	BC,10000
	CALL	@NETDRV.WAIT_LINK_UP
	JP	C,NETWORK_FAIL
	LD	HL,MSG_P4
	CALL	REPORT_LINE
	; WAIT_LINK_UP counts its own CYCLES21 quanta, so the link stage gets
	; millisecond resolution the RTC cannot give the others.
	LD	HL,MSG_WAITQ
	CALL	@CONSOLE.STRING
	LD	HL,(EL3_LAST_TICKS)
	CALL	@CONSOLE.DEC16
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING

	; The first frame on the wire. UDPX.OPEN runs the same shared ARP
	; schedule (netdrv.inc) that TCPX.OPEN does, so the seconds printed
	; here and the TRY= that follows them are exactly what FTP spends
	; after its "Host x -> y" line.
	CALL	PARSE_TARGET
	LD	HL,MSG_TARGET
	CALL	@CONSOLE.STRING
	LD	HL,NP_TARGET
	CALL	PRINT_IP
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	HL,MSG_P5
	CALL	TIME_ARP
	; ...and again from a cold cache. Every utility clears the ARP cache at
	; startup, so the cold resolve is what they all pay; a second cold one
	; that comes back instantly means the cost is something outside this
	; machine warming up, not the resolver.
	LD	HL,MSG_P6
	CALL	TIME_ARP

	; What a NETTIME millisecond is actually worth. Every timeout in the kit
	; is counted in S9APP.WAIT_TICK calls against a fixed 21 MHz budget of
	; 1000 per second; if the real machine delivers fewer, every deadline in
	; the project runs long by that ratio. Counting them between two RTC
	; second edges measures it directly, and costs one second to do.
	CALL	TICKS_PER_SECOND
	LD	HL,MSG_P7
	CALL	@CONSOLE.STRING
	LD	HL,(NP_TICKS)
	CALL	@CONSOLE.DEC16
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING

	; The same quantum with the syscall taken out of it. NETTIME.TICK now
	; consults the wall clock only once every NETTIME_WALL_EVERY quanta, so
	; what paces a deadline between those checks is the busy loop alone.
	; NP_PURE_TICKS of them between two wall reads report milliseconds per
	; quantum directly at a tenth of a millisecond of resolution, which is
	; the number WAIT_TICK's loop count has to be calibrated against: the
	; loop is sized for 21 MHz with no bus waits, and P7 says the machine
	; does not deliver that. Expect roughly twenty seconds of blank screen.
	CALL	MARK
	LD	HL,NP_PURE_TICKS
PURE_TICK_LOOP
	PUSH	HL
	CALL	@S9APP.WAIT_TICK
	POP	HL
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,PURE_TICK_LOOP
	LD	HL,MSG_P8
	CALL	REPORT_LINE
	JP	SUCCESS

; TICKS_PER_SECOND counts WAIT_TICK calls across one whole RTC second, from
; edge to edge so the sample is a full second rather than a fraction of one.
; Both loops are bounded by the same counter: a clock that never advances
; reports NP_TICKS_LIMIT instead of spinning forever.
NP_TICKS_LIMIT		EQU 60000
; Ten thousand quanta: one wall second of error over a sample that a correctly
; sized quantum would finish in ten, so the reading is good to a tenth of a
; millisecond either way.
NP_PURE_TICKS		EQU 10000
TICKS_PER_SECOND
	CALL	@NETTIME.READ_WALL
	LD	(NP_MARK),HL
	CALL	.RESET_COUNT
.EDGE
	CALL	.BUMP
	RET	C
	CALL	@NETTIME.READ_WALL
	LD	DE,(NP_MARK)
	OR	A
	SBC	HL,DE
	JR	Z,.EDGE
	CALL	@NETTIME.READ_WALL
	LD	(NP_MARK),HL
	CALL	.RESET_COUNT
.COUNT
	CALL	@S9APP.WAIT_TICK
	CALL	.BUMP
	RET	C
	CALL	@NETTIME.READ_WALL
	LD	DE,(NP_MARK)
	OR	A
	SBC	HL,DE
	JR	Z,.COUNT
	RET
.RESET_COUNT
	LD	HL,0
	LD	(NP_TICKS),HL
	RET
.BUMP
	LD	HL,(NP_TICKS)
	INC	HL
	LD	(NP_TICKS),HL
	LD	DE,NP_TICKS_LIMIT
	OR	A
	SBC	HL,DE
	CCF
	RET

; TIME_ARP: HL -> stage label. Clears the cache, resolves NP_TARGET and
; reports the stage plus the attempt the reply arrived on.
TIME_ARP
	PUSH	HL
	CALL	@ARP.CLEAR_CACHE
	XOR	A
	LD	(ARP_RETRY_LEFT),A
	CALL	MARK
	LD	HL,NP_TARGET
	LD	BC,7			; discard, never actually sent to
	LD	DE,7
	CALL	@UDPX.OPEN
	JP	C,NETWORK_FAIL
	POP	HL
	CALL	REPORT
	LD	HL,MSG_TRIES
	CALL	@CONSOLE.STRING
	; The retry counter counts down, so ARP_ATTEMPTS_MAX+1 minus what is
	; left is the attempt that answered. A cache hit leaves the zero set
	; above and reports one past the last attempt, which cannot be confused
	; with a real one.
	LD	A,ARP_ATTEMPTS_MAX+1
	LD	HL,ARP_RETRY_LEFT
	SUB	(HL)
	CALL	@CONSOLE.DEC8
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

; SCAN_NO_RESET looks for -n before anything touches the adapter. It has to
; run this early because the reset it suppresses is the very first thing
; DISCOVER does. Anywhere on the line, either case; PARSE_TARGET skips the
; flag token so an address can follow it.
SCAN_NO_RESET
	LD	HL,(CMDLINE_SOURCE)
	LD	A,(HL)
	CP	2			; a two-character flag needs two characters
	RET	C
	DEC	A			; the last one cannot start it
	LD	B,A
	INC	HL
.SCAN
	LD	A,(HL)
	INC	HL
	CP	'-'
	JR	NZ,.NEXT
	LD	A,(HL)
	AND	0xDF			; fold case: -n and -N
	CP	'N'
	JR	NZ,.NEXT
	LD	A,1
	LD	(@EL3.SKIP_GLOBAL_RESET),A
	RET
.NEXT
	DJNZ	.SCAN
	RET

; PARSE_TARGET takes one optional dotted IPv4 from the command line and
; falls back to the configured gateway, which every utility ARPs anyway.
PARSE_TARGET
	LD	HL,NET_GATEWAY
	LD	DE,NP_TARGET
	CALL	COPY4
	LD	HL,(CMDLINE_SOURCE)
	LD	A,(HL)
	OR	A
	RET	Z
	LD	B,A
	INC	HL
	; The command arrives length-prefixed, not terminated. PARSE_IPV4 stops
	; at the first non-digit, so without this it would run into whatever
	; follows the command in the page.
	PUSH	HL
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	(HL),0
	POP	HL
.SKIP
	LD	A,(HL)
	CP	' '
	JR	Z,.ADVANCE
	CP	'-'
	JR	NZ,.PARSE
.FLAG					; step over a -x token and its trailing
	INC	HL			; space so the address can follow it
	DEC	B
	RET	Z
	LD	A,(HL)
	CP	' '
	JR	NZ,.FLAG
.ADVANCE
	INC	HL
	DJNZ	.SKIP
	RET
.PARSE
	LD	DE,NP_TARGET
	CALL	@S9APP.PARSE_IPV4
	RET	NC
	LD	HL,NET_GATEWAY		; unparsable text keeps the gateway
	LD	DE,NP_TARGET
COPY4
	LD	BC,4
	LDIR
	RET

PRINT_IP
	LD	B,4
.NEXT
	LD	A,(HL)
	INC	HL
	PUSH	HL,BC
	CALL	@CONSOLE.DEC8
	POP	BC,HL
	DEC	B
	RET	Z
	LD	A,'.'
	CALL	@CONSOLE.CHAR
	JR	.NEXT

; TRY_DISCOVER: A=slot. Out: CF=0 and NP_SLOT set when this slot answered.
; Read-only, and a miss leaves nothing behind for NETDRV.INIT to trip over.
TRY_DISCOVER
	LD	(NP_SLOT),A
	LD	HL,(NETDRV_CONFIG+NETDRV_CFG_IDPORT)
	CALL	@EL3.CONFIGURE
	RET	C
	JP	@EL3.DISCOVER

; MARK stores the current second-within-the-hour. READ_WALL is the only clock
; this kit has that fits a register pair; an hour wrap is folded back in
; REPORT, so a run straddling the hour still reports honest deltas.
MARK
	CALL	@NETTIME.READ_WALL
	LD	(NP_MARK),HL
	RET

; REPORT: HL -> stage label. Prints "<label>=<seconds>s" and re-marks, so
; each stage is measured from the end of the previous one.
REPORT
	PUSH	HL
	CALL	@NETTIME.READ_WALL
	LD	DE,(NP_MARK)
	OR	A
	SBC	HL,DE
	JR	NC,.NO_WRAP
	LD	DE,3600
	ADD	HL,DE
.NO_WRAP
	; The delta goes to storage, not to a register pair: CONSOLE.STRING
	; reaches DSS_PCHARS and does not promise BC back.
	LD	(NP_DELTA),HL
	POP	HL
	CALL	@CONSOLE.STRING
	LD	HL,(NP_DELTA)
	CALL	@CONSOLE.DEC16
	LD	HL,MSG_SECONDS
	CALL	@CONSOLE.STRING
	JP	MARK

; REPORT_LINE is REPORT plus the line break, for the stages that have nothing
; else to say about themselves.
REPORT_LINE
	CALL	REPORT
	LD	HL,@CONSOLE.CRLF
	JP	@CONSOLE.STRING

SUCCESS
	LD	A,DSS_EXIT_LOCAL
	LD	(S9_EXIT_CODE),A
	XOR	A
	CALL	@S9APP.CLEANUP
	JR	C,LOCAL_FAIL_DIRECT
	LD	HL,MSG_OK
	CALL	@CONSOLE.LINE
	DSS_RETURN DSS_EXIT_OK
CONFIG_FAIL
	LD	B,DSS_EXIT_CONFIG
	JR	FAIL
HARDWARE_FAIL
	LD	B,DSS_EXIT_HARDWARE
	JR	FAIL
NETWORK_FAIL
	LD	B,DSS_EXIT_NETWORK
FAIL
	LD	C,A
	LD	A,B
	LD	(S9_EXIT_CODE),A
	LD	A,C
	CALL	@S9APP.CLEANUP
LOCAL_FAIL_DIRECT
	LD	(NETDRV_FAIL_CODE),A
	LD	HL,MSG_FAIL
	CALL	@CONSOLE.STRING
	LD	A,(NETDRV_FAIL_CODE)
	CALL	@CONSOLE.DEC8
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	LD	A,(S9_EXIT_CODE)
	LD	B,A
	LD	C,DSS_EXIT
	RST	DSS
BOOT_FAIL
	LD	(NETDRV_FAIL_CODE),A
	LD	HL,MSG_FAIL
	CALL	@CONSOLE.STRING
	LD	A,(NETDRV_FAIL_CODE)
	CALL	@CONSOLE.DEC8
	LD	HL,@CONSOLE.CRLF
	CALL	@CONSOLE.STRING
	DSS_RETURN DSS_EXIT_LOCAL

NP_MARK		DW 0
NP_TARGET	DS 4,0
NP_DELTA	DW 0
NP_TICKS	DW 0
NP_SLOT		DB 0xFF

MSG_BANNER	DB "3C509B NETPROF v",PACKAGE_VERSION,0
MSG_P1		DB "[P1] CONFIG=",0
MSG_P2		DB "[P2] DISCOVER=",0
MSG_P3		DB "[P3] DRIVER=",0
MSG_P4		DB "[P4] LINK=",0
MSG_P5		DB "[P5] ARP=",0
MSG_P6		DB "[P6] ARP2=",0
MSG_P7		DB "[P7] TICKS/SEC=",0
MSG_P8		DB "[P8] 10K TICKS=",0
MSG_NORESET	DB "[P2] GLOBAL RESET=SKIPPED",0
MSG_SECONDS	DB "s",0
MSG_SLOT	DB "[P2] EEPROM SLOT=",0
MSG_TARGET	DB "[P5] TARGET=",0
MSG_TRIES	DB " TRY=",0
MSG_WAITQ	DB "[P4] LINK QUANTA=",0
MSG_OK		DB "RESULT OK",0
MSG_FAIL	DB "RESULT FAIL code=",0

	ENDMODULE

	INCLUDE "el3_algorithms.asm"
	INCLUDE "console.asm"
	INCLUDE "isa.asm"
	INCLUDE "el3_io.asm"
	INCLUDE "el3_fifo.asm"
	INCLUDE "el3_regs.asm"
	INCLUDE "el3.asm"
	INCLUDE "netdrv.asm"
	INCLUDE "ethernet.asm"
	INCLUDE "../lib/arp.asm"
	INCLUDE "ipv4.asm"
	INCLUDE "icmp.asm"
	INCLUDE "udp.asm"
	INCLUDE "dns.asm"
	INCLUDE "stage9_app.asm"
	INCLUDE "nettime.asm"
	INCLUDE "udp_transport.asm"
	INCLUDE "stage10_app.asm"

	ASSERT $ + S10_BOOTSTRAP_STACK_RESERVE <= S10_STACK_TOP
