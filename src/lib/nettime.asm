; Clock-independent bounded polling timebase for Stage 8.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_NETTIME_ASM
	DEFINE	_NETTIME_ASM

	INCLUDE "dss.inc"
	INCLUDE "memory.inc"
	INCLUDE "el3.inc"

	MODULE NETTIME

; WAIT_TICK is one millisecond on a real Sprinter: its loop count
; (NETTIME_TICK_LOOP, netdrv.inc) is sized from a NETPROF measurement of the
; machine rather than from the 21 MHz instruction timing, which the bus does
; not deliver. Keep timeout conversion deterministic: client startup must not
; spend a wall-clock second measuring a value the target's timing contract
; already fixes.
NETTIME_FIXED_QPS	EQU 1000
NETTIME_FIXED_MS	EQU 1

; How many quanta TICK lets pass between two consultations of the wall clock.
; The wall limit is a coarse backstop against a monotonic base that has stopped
; advancing, not the deadline itself, and it is expressed in whole seconds -- it
; has never needed millisecond resolution. Reading it every quantum did cost
; that much: READ_WALL is an RST into DSS, and NETPROF measures the pair
; WAIT_TICK + READ_WALL at 348 per second on a real Sprinter against the 1000
; the fixed base assumes, so the syscall is a large and DSS-dependent part of
; a quantum. Must be a power of two: TICK tests the low bits of the countdown.
NETTIME_WALL_EVERY	EQU 64

	IFNDEF STAGE12_LAYOUT
; INIT loads the fixed 21 MHz timebase. It is idempotent and has no delay.
INIT
	LD	HL,NETTIME_FIXED_QPS
	LD	(NETTIME_QPS),HL
	LD	HL,NETTIME_FIXED_MS
	LD	(NETTIME_MS_PER_QUANTUM),HL
	XOR	A
	RET

; Compatibility entry point for older clients. Calibration is intentionally a
; zero-delay fixed-base initialization; all production clients use INIT via
; START below.
CALIBRATE
	JP	INIT
	ENDIF

; START
; In BC=timeout milliseconds 1..65535. Converts it to monotonic polling
; quanta using the fixed 21 MHz rate and arms an additional coarse wall
; watchdog.
START
	IFDEF STAGE12_LAYOUT
	PUSH	IX,IY
	LD	A,B
	OR	C
	JR	Z,.START_BAD_COMPACT
	LD	(NETTIME_TIMEOUT_MS),BC
	LD	(NETTIME_QUANTA_LEFT),BC
	LD	(NETTIME_QUANTA_TOTAL),BC
	LD	HL,0
	LD	(NETTIME_ELAPSED_MS),HL
	INC	HL
	LD	(NETTIME_MS_PER_QUANTUM),HL
	LD	HL,68			; > ceil(65535/1000)+2, monotonic limit stays primary
	LD	(NETTIME_WALL_LIMIT),HL
	; TICK consults the wall backstop only when the countdown crosses a
	; multiple of NETTIME_WALL_EVERY, which a timeout of at most that many
	; quanta never does -- so the reference read here would never be looked
	; at. Skip it: READ_WALL is a DSS_SYSTIME (about 2 ms on a real
	; Sprinter, see NETTIME_WALL_EVERY above), and it was the larger part
	; of every one-quantum RECV poll a client makes with IY=0.
	LD	HL,NETTIME_WALL_EVERY
	OR	A
	SBC	HL,BC			; CF=0: timeout <= WALL_EVERY quanta
	JR	NC,.START_NO_WALL
	CALL	READ_WALL
	LD	(NETTIME_START_WALL),HL
.START_NO_WALL
	XOR	A
	POP	IY,IX
	RET
.START_BAD_COMPACT
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET
	ELSE
	PUSH	IX,IY
	LD	A,B
	OR	C
	JR	Z,.START_BAD
	CALL	INIT
	LD	(NETTIME_TIMEOUT_MS),BC
	LD	HL,0
	LD	(NETTIME_QUANTA_LEFT),HL
	LD	(NETTIME_ELAPSED_MS),HL
	LD	DE,0			; fractional qps/1000 accumulator
.QUANTUM_MS
	LD	HL,(NETTIME_QPS)
	ADD	HL,DE
	EX	DE,HL
	LD	HL,DE
	LD	DE,1000
	OR	A
	SBC	HL,DE
	JR	C,.NO_WHOLE_QUANTUM
	EX	DE,HL			; DE=remainder
	LD	HL,(NETTIME_QUANTA_LEFT)
	INC	HL
	LD	(NETTIME_QUANTA_LEFT),HL
	JR	.NEXT_MS
.NO_WHOLE_QUANTUM
	ADD	HL,DE			; restore pre-subtraction accumulator
	EX	DE,HL
.NEXT_MS
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.QUANTUM_MS
	LD	A,D
	OR	E
	JR	Z,.QUANTA_READY
	LD	HL,(NETTIME_QUANTA_LEFT)
	INC	HL
	LD	(NETTIME_QUANTA_LEFT),HL
.QUANTA_READY
	LD	HL,(NETTIME_QUANTA_LEFT)
	LD	A,H
	OR	L
	JR	NZ,.HAVE_QUANTA
	INC	HL
	LD	(NETTIME_QUANTA_LEFT),HL
.HAVE_QUANTA
	LD	(NETTIME_QUANTA_TOTAL),HL
	; ceil(timeout_ms/1000)+2 seconds for a stopped DSS wall clock.
	LD	HL,(NETTIME_TIMEOUT_MS)
	LD	BC,0
.WALL_DIVIDE
	LD	DE,1000
	OR	A
	SBC	HL,DE
	JR	C,.WALL_REMAINDER
	INC	BC
	JR	.WALL_DIVIDE
.WALL_REMAINDER
	ADD	HL,DE			; restore value before the failed subtraction
	LD	A,H
	OR	L
	JR	Z,.WALL_ADD_GUARD
	INC	BC
.WALL_ADD_GUARD
	INC	BC
	INC	BC
	LD	(NETTIME_WALL_LIMIT),BC
	CALL	READ_WALL
	LD	(NETTIME_START_WALL),HL
	XOR	A
	POP	IY,IX
	RET
	ENDIF
.START_BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET

; TICK performs one fixed-base finite delay. Out: Z/CF clear while live;
; A=EL3_ERR_RX_TIMEOUT/CF set when either monotonic or wall limit expires.
TICK
	PUSH	IX,IY
	LD	HL,(NETTIME_ELAPSED_MS)
	LD	DE,(NETTIME_MS_PER_QUANTUM)
	ADD	HL,DE
	JR	C,.ELAPSED_SATURATE
	LD	DE,(NETTIME_TIMEOUT_MS)
	OR	A
	SBC	HL,DE
	JR	C,.ELAPSED_RESTORE
	JR	Z,.ELAPSED_LIMIT
.ELAPSED_SATURATE
	LD	HL,(NETTIME_TIMEOUT_MS)
	JR	.ELAPSED_STORE
.ELAPSED_RESTORE
	ADD	HL,DE
	JR	.ELAPSED_STORE
.ELAPSED_LIMIT
	ADD	HL,DE
.ELAPSED_STORE
	LD	(NETTIME_ELAPSED_MS),HL
	LD	HL,(NETTIME_QUANTA_LEFT)
	LD	A,H
	OR	L
	JR	Z,.EXPIRED
	DEC	HL
	LD	(NETTIME_QUANTA_LEFT),HL
	LD	A,H
	OR	L
	JR	Z,.EXPIRED
	; Pace only a quantum that stays live: the last one expires the moment
	; it is counted, and waiting first merely delayed that verdict by a
	; millisecond. This turns a one-quantum RECV (UNET IY=0: "take what is
	; there and return") into a pure card poll instead of a 1 ms stall on
	; every idle call; every longer timeout simply ends one quantum early.
	CALL	@S7APP.WAIT_TICK	; keeps HL
	LD	A,L
	AND	NETTIME_WALL_EVERY-1
	JR	NZ,.LIVE		; between backstop checks
	CALL	READ_WALL
	LD	DE,(NETTIME_START_WALL)
	OR	A
	SBC	HL,DE
	JR	NC,.WALL_DELTA
	LD	DE,3600
	ADD	HL,DE
.WALL_DELTA
	LD	DE,(NETTIME_WALL_LIMIT)
	OR	A
	SBC	HL,DE
	JR	NC,.EXPIRED
.LIVE
	XOR	A
	POP	IY,IX
	RET
.EXPIRED
	LD	A,EL3_ERR_RX_TIMEOUT
	SCF
	POP	IY,IX
	RET

; READ_WALL returns HL=second within the current hour (0..3599).
READ_WALL
	LD	C,DSS_SYSTIME
	RST	DSS
	LD	A,B
	LD	(NETTIME_CAL_SECOND),A
	LD	A,L
	LD	HL,0
	LD	DE,60
	OR	A
	JR	Z,.ADD_SECONDS
	LD	B,A
.MINUTES
	ADD	HL,DE
	DJNZ	.MINUTES
.ADD_SECONDS
	LD	A,(NETTIME_CAL_SECOND)
	LD	E,A
	LD	D,0
	ADD	HL,DE
	RET

	IFNDEF STAGE12_LAYOUT
READ_SECOND
	LD	C,DSS_SYSTIME
	RST	DSS
	LD	A,B
	RET
	ENDIF

	ENDMODULE
	ENDIF
