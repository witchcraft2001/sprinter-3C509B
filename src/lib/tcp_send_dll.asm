; Resumable DLL SEND. The cold planner owns all persistent state; this hot
; executor alone polls the NIC and transmits. Included inside MODULE TCPX.
; In A=channel, HL=buffer, BC=length. Out CF/status, DE=confirmed prefix.
; Clobbers AF/BC/HL, preserves IX/IY. No live call stack survives AGAIN.
SEND
	PUSH	IX,IY
	LD	(S11_SEND_POINTER),HL
	LD	(S11_SEND_REMAINING),BC
	LD	HL,0
	LD	(S11_SEND_CONFIRMED),HL
	LD	(S11_ACTIVE_LENGTH),HL
	LD	(S11_SEND_PHASE),HL
	CALL	SELECT_CONTEXT
	JP	C,SEND_EXIT
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_ESTABLISHED
	JR	Z,.CHECK_STREAM
	CP	TCP_STATE_CLOSE_WAIT
	LD	A,TCP_ERR_CLOSED
	JR	NZ,SEND_ERROR
.CHECK_STREAM
	; A final error can leave bytes in flight. A new buffer must never be
	; numbered from SND.UNA while SND.NXT still includes the previous buffer.
	BIT	CTX_SEND_FAILED_BIT,(IX+CTX_WINDOW_CLOSED)
	LD	A,TCP_ERR_SEND_FAILED
	JR	NZ,SEND_ERROR
	CALL	SEND_STREAM_CHECK
	LD	A,TCP_ERR_SEND_FAILED
	JR	NZ,SEND_ERROR
	JR	SEND_BEGIN_CALL

; Only the shim's identical channel/buffer/length contract may enter here.
SEND_RESUME
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JR	C,SEND_EXIT
SEND_BEGIN_CALL
	LD	IY,S11_STATE_BASE
	LD	BC,(UNET_OPT_SLICE)
	LD	A,CFN_SEND_BEGIN
	CALL	@COLD.RUN
	; Buffered RECV can reopen either receive window between continuations.
	; Send the deferred updates before polling, preserving the SEND context.
	; A TX failure is terminal for this SEND, even on the other channel's
	; ACK. SEND_ERROR also latches refusal if the owner has bytes in flight.
	PUSH	IX
	LD	IX,S11_CONTEXT0
	CALL	SEND_RECV_UPDATE
	PUSH	AF
	LD	IX,S11_CONTEXT1
	CALL	SEND_RECV_UPDATE
	POP	BC
	JR	C,.UPDATED
	LD	A,B
	RR	C			; preserve context 0's failure after trying both
.UPDATED
	POP	IX
	JR	C,SEND_ERROR
SEND_STEP
	LD	IX,(S11_SELECTED_CONTEXT)
	LD	IY,S11_STATE_BASE
	LD	A,CFN_SEND_STEP
	CALL	@COLD.RUN
	JR	C,SEND_ERROR
	OR	A
	JR	Z,SEND_EXIT
	CP	DLL_SEND_DATA
	JR	Z,SEND_DATA
	CP	DLL_SEND_PROBE
	JR	Z,SEND_PROBE
	; BC=min(attempt remaining, public call remaining), always nonzero.
	LD	A,EVENT_ACK|EVENT_WINDOW|EVENT_FIN|EVENT_RST
	CALL	WAIT_FOR_EVENT
	PUSH	AF
	LD	IY,S11_STATE_BASE
	LD	DE,(NETTIME_ELAPSED_MS)
	LD	A,CFN_SEND_CHARGE
	CALL	@COLD.RUN
	POP	AF
	LD	E,A
	JR	NC,.RESULT
	CP	TCP_ERR_TIMEOUT
	JR	NZ,SEND_ERROR
.RESULT
	LD	A,CFN_SEND_RESULT
	CALL	@COLD.RUN
	JR	NC,SEND_STEP
SEND_ERROR
	CP	TCP_ERR_AGAIN
	JR	Z,.STATUS
	PUSH	AF
	LD	IX,(S11_SELECTED_CONTEXT)
	CALL	SEND_STREAM_CHECK
	JR	Z,.UNCHANGED
	SET	CTX_SEND_FAILED_BIT,(IX+CTX_WINDOW_CLOSED)
.UNCHANGED
	POP	AF
.STATUS
	SCF
SEND_EXIT
	LD	DE,(S11_SEND_CONFIRMED)
	POP	IY,IX
	RET
SEND_DATA
	; RX and TX share storage: always rebuild from the saved caller pointer.
	LD	HL,(S11_SEND_POINTER)
	LD	DE,TCPX_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	LD	BC,(S11_ACTIVE_LENGTH)
	LDIR
	LD	BC,(S11_ACTIVE_LENGTH)
	LD	A,TCP_FLAG_PSH|TCP_FLAG_ACK
	CALL	SEND_SEGMENT
	JR	NC,SEND_STEP
	; Only an unsuccessful first transmission can rewind SND.NXT safely.
	PUSH	AF
	LD	A,(IX+CTX_RETRY_LEFT)
	CP	DLL_SEND_ATTEMPTS
	JR	NZ,.FAILED
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_UNA
	ADD	HL,DE
	LD	D,H
	LD	E,L
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	CALL	COPY4
.FAILED
	POP	AF
	JR	SEND_ERROR
SEND_PROBE
	CALL	SEND_WINDOW_PROBE
	JP	NC,SEND_STEP
	JR	SEND_ERROR

; In IX=context; preserves IX, clobbers AF/BC/DE/HL/IY.
; CF/status propagates a failed window ACK; a closed context does no work.
SEND_RECV_UPDATE
	LD	A,(IX+CTX_STATE)
	OR	A
	RET	Z			; a reset/failed context cannot reopen a window
	BIT	1,(IX+CTX_WINDOW_CLOSED)
	RET	Z
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT
	RET	C			; a failed update must remain pending for RECV
	RES	1,(IX+CTX_WINDOW_CLOSED)
	RET

; IX=context. Z iff no bytes are outstanding. Clobbers AF/DE/HL.
SEND_STREAM_CHECK
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_UNA
	ADD	HL,DE
	LD	D,H
	LD	E,L
	INC	DE
	INC	DE
	INC	DE
	INC	DE
	JP	CMP4
