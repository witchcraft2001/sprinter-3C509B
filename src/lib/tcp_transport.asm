; Polling-only two-channel TCP/IPv4 client over NETDRV.
; SPDX-License-Identifier: BSD-3-Clause

	IFNDEF	_TCP_TRANSPORT_ASM
	DEFINE	_TCP_TRANSPORT_ASM

	INCLUDE "dss.inc"
	INCLUDE "memory.inc"
	INCLUDE "netdrv.inc"
	INCLUDE "ip_icmp.inc"
	INCLUDE "tcp.inc"

	IFDEF STAGE12_LAYOUT
; The pending buffer must hold a whole TCP_RECV_WINDOW so a burst of segments
; arriving before the app drains via RECV can be appended rather than
; rejected -- see PROCESS_FRAME's accept path.
	IFDEF TCPX_SPLIT_PENDING
; Only the bulk channel carries a window's worth. The other advertises its
; own free space and never promises more than it can store (PENDING_FREE),
; so one whole segment is all it owes; below that a single arriving segment
; could never be queued at all.
	ASSERT S11_PENDING1_CAPACITY >= TCP_RECV_WINDOW
	ASSERT S11_PENDING_CAPACITY >= TCP_MSS
	ELSE
	ASSERT S11_PENDING_CAPACITY >= TCP_RECV_WINDOW
	ENDIF
	ENDIF

; TCPX_TX_BUFFER: every outgoing TCP segment (SYN/data/ACK/FIN/RST) this
; module builds via SEND_SEGMENT_COMMON, plus its own outgoing ARP
; requests -- never its ARP REPLIES, see below -- is a frame we are
; constructing fresh; none of them ever needs to read the RX buffer's
; current contents at the same time (any inbound payload a segment might
; ACK is already copied out of RX before SEND_SEGMENT runs -- see
; HANDLE_SEGMENT's own long comment on segment length). So for the DLL,
; which has no spare page for a second reservation the size of
; TCP_MSS+headers, this reuses the otherwise-idle RX buffer instead (the
; same trick UDP's own UDPX_TX_BUFFER already uses). ARP REPLY building
; is different -- ARP_BUILD_REPLY reads fields from the very request
; frame it is still writing the reply into -- so PROCESS_ARP and
; RESOLVE_ROUTE's own reply-to-a-request branch keep using the small,
; separate STAGE9_TX_BUFFER (60 bytes, exactly one ARP frame, see
; unet509b_bss.inc) instead of this alias; do not redirect those two call
; sites to TCPX_TX_BUFFER.
	IFDEF	UNET_DLL
TCPX_TX_BUFFER		EQU STAGE9_RX_BUFFER
TCPX_TX_CAPACITY	EQU STAGE9_RX_CAPACITY
	ELSE
TCPX_TX_BUFFER		EQU STAGE9_TX_BUFFER
TCPX_TX_CAPACITY	EQU STAGE9_TX_CAPACITY
	ENDIF

; TCPX_SINGLE_CONTEXT restricts the transport to channel 0 only: RESET clears
; just one context, SELECT_CONTEXT rejects channel 1, and PROCESS_FRAME never
; falls through to a second context. WGET and DLSPEED want this -- one stream
; is all either ever opens. The FTP client needs both channels live at once
; (control + data) and defines STAGE13_LAYOUT precisely to opt back into the
; two-channel code below despite also defining STAGE12_LAYOUT for its
; layout/trims (deep window, standard DSS layout, own diagnostics).
	IFDEF STAGE12_LAYOUT
	IFNDEF STAGE13_LAYOUT
	DEFINE TCPX_SINGLE_CONTEXT
	ENDIF
	ENDIF

; TCPX_WAIT_PROGRESS builds the bounded tick skip in .WAIT_LOOP. Only the
; builds that actually land on that branch carry it: the session receive path
; reaches it after delivering a segment straight to the caller, and the burst
; sender reaches it on the acknowledgement of a pair's first segment, which
; HANDLE_SEGMENT deliberately ignores. WGET and TCPTEST reach it never --
; measured, not assumed, with the harness's delayLoops counter -- so they keep
; the plain tick and the image bytes.
	IFDEF EL3_SESSION_RX
	DEFINE TCPX_WAIT_PROGRESS
	ENDIF
	IFDEF TCPX_SEND_BURST
	IFNDEF TCPX_WAIT_PROGRESS
	DEFINE TCPX_WAIT_PROGRESS
	ENDIF
	ENDIF

	MODULE TCPX
	INCLUDE "tcpctx.inc"

; Ethernet + fixed IPv4 + fixed TCP header. The two-phase receive reads
; exactly this much of a frame before deciding what to do with the rest.
TCPX_RX_PREFIX		EQU 14 + IPV4_HEADER_LENGTH + TCP_HEADER_LENGTH
; How many productive polls in a row .WAIT_PROGRESS may skip NETTIME.TICK for
; before spending one anyway. 64 segments is well inside any single RECV's
; deadline yet still bounds a flood of frames that never raise an event.
WAIT_PROGRESS_QUANTA	EQU 64

; S11_SEQUENCE_OVERRIDE selects where SEND_SEGMENT_COMMON reads the outgoing
; sequence number from when it may not come from the context itself.
SEQUENCE_FROM_CONTEXT	EQU 0	; ordinary segment: SND.UNA or SND.NXT
SEQUENCE_FROM_TARGET	EQU 1	; window probe: SND.NXT-1, staged in TARGET_ACK
SEQUENCE_FROM_BURST	EQU 2	; burst's second segment: SND.UNA + first length

SYN_ATTEMPTS		EQU 3
SYN_TIMEOUT_MS		EQU 1700
DATA_ATTEMPTS		EQU 3
FIN_TIMEOUT_MS		EQU 5000
ARP_ATTEMPTS		EQU ARP_ATTEMPTS_MAX
ARP_TIMEOUT_MS		EQU ARP_RETRY_MS

; RESET clears both channel contexts. It does not touch NETDRV and preserves a
; valid ephemeral-port cursor so reconnect cannot immediately reuse its tuple.
; Out: A=0/CF=0. Clobbers AF/BC/HL; preserves IX/IY.
RESET
	PUSH	IX,IY
	LD	HL,S11_CONTEXT0
	LD	BC,S11_CONTEXT_SIZE
	CALL	ZERO_REGION
	IFNDEF	TCPX_SINGLE_CONTEXT
	LD	HL,S11_CONTEXT1
	LD	BC,S11_CONTEXT_SIZE
	CALL	ZERO_REGION
	ENDIF
	LD	HL,(S11_NEXT_LOCAL_PORT)
	LD	A,H
	CP	0xC0
	JP	NC,.PORT_READY
	LD	A,(NET_LOCAL_IP+3)
	LD	B,A
	LD	A,R
	XOR	B
	LD	L,A
	LD	A,R
	AND	0x3F
	OR	0xC0
	LD	H,A
	LD	(S11_NEXT_LOCAL_PORT),HL
.PORT_READY
	LD	HL,1
	LD	(S11_IP_ID),HL
	IFDEF	EL3_SESSION_RX
	LD	HL,0
	LD	(S11_RX_FREE),HL	; no RECV is waiting: direct delivery off
	LD	(S11_RX_DELIVERED),HL
	XOR	A
	LD	(S11_ACK_OWED),A
	ENDIF
	XOR	A
	POP	IY,IX
	RET

; OPEN
; In: A=channel 0..1, HL=remote IPv4 pointer, BC=remote port.
; Out: CF/A status. Local port and ISN are generated per call.
; Clobbers AF/BC/DE/HL; preserves IX/IY.
OPEN
	LD	(S11_CHANNEL),A
	JP	OPEN_SAFE

OPEN_SAFE
	PUSH	IX,IY
	LD	(S11_SEND_POINTER),HL
	LD	(S11_SEND_REMAINING),BC
	LD	A,B
	OR	C
	JP	Z,.PARAMETER_SAFE
	LD	BC,4
	CALL	@IPV4.VALIDATE_REGION
	JP	C,.PARAMETER_SAFE
	LD	A,(S11_CHANNEL)
	CALL	SELECT_CONTEXT
	JP	C,.RETURN_SAFE
	LD	A,(IX+CTX_STATE)
	OR	A
	JP	NZ,.STATE_SAFE
	CALL	CLEAR_CONTEXT
	LD	HL,(S11_SEND_POINTER)
	PUSH	IX
	POP	DE
	INC	DE
	LD	BC,4
	LDIR
	LD	HL,(S11_SEND_REMAINING)
	LD	(IX+CTX_REMOTE_PORT),L
	LD	(IX+CTX_REMOTE_PORT+1),H
	LD	HL,TCP_MSS
	LD	(IX+CTX_PEER_MSS),L
	LD	(IX+CTX_PEER_MSS+1),H
	LD	A,TCP_STAGE_ARP
	LD	(S11_DIAG_STAGE),A
	CALL	RESOLVE_ROUTE
	JP	C,.FAIL_OPEN
	LD	HL,NET_RESULT_MAC
	PUSH	IX
	POP	DE
	LD	BC,CTX_REMOTE_MAC
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	HL,NET_RESULT_MAC
	LD	BC,6
	LDIR
	CALL	GENERATE_TUPLE
	LD	(IX+CTX_STATE),TCP_STATE_SYN_SENT
	LD	A,TCP_STAGE_SYN
	LD	(S11_DIAG_STAGE),A
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	CALL	INC32
	LD	(IX+CTX_RETRY_LEFT),SYN_ATTEMPTS
.SYN_TRY
	XOR	A
	LD	(IX+CTX_EVENT),A
	LD	A,TCP_FLAG_SYN
	LD	BC,0
	CALL	SEND_SEGMENT
	JP	C,.FAIL_OPEN
	LD	A,EVENT_SYN_ACK|EVENT_RST
	LD	BC,SYN_TIMEOUT_MS
	CALL	WAIT_FOR_EVENT
	JP	NC,.SYN_EVENT
	CP	TCP_ERR_TIMEOUT
	JP	NZ,.FAIL_OPEN
	LD	A,(IX+CTX_RETRY_LEFT)
	DEC	A
	LD	(IX+CTX_RETRY_LEFT),A
	JP	NZ,.SYN_TRY
	LD	A,TCP_ERR_TIMEOUT
	JP	.FAIL_OPEN
.SYN_EVENT
	BIT	3,A
	JP	NZ,.RESET_OPEN
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_ESTABLISHED
	JP	NZ,.PROTOCOL_OPEN
	XOR	A
	POP	IY,IX
	RET
.RESET_OPEN
	LD	A,TCP_ERR_RESET
	JP	.FAIL_OPEN
.PROTOCOL_OPEN
	LD	A,NETDRV_ERR_PROTOCOL
.FAIL_OPEN
	CALL	FAIL_CONTEXT
.RETURN_SAFE
	POP	IY,IX
	RET
.STATE_SAFE
	LD	A,TCP_ERR_STATE
	SCF
	POP	IY,IX
	RET
.PARAMETER_SAFE
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	POP	IY,IX
	RET

; SEND
; In: A=channel, HL=buffer, BC=length. Out: DE=cumulatively ACKed bytes.
; Length zero is a successful no-op on an open channel; longer calls are
; segmented internally. Under TCPX_SEND_BURST a round trip carries two
; segments instead of one whenever the buffer and the peer's window allow it
; (CHOOSE_BURST); either way the wait below is for one cumulative
; acknowledgement covering everything that went out.
; Clobbers AF/BC/HL; preserves IX/IY.
SEND
	PUSH	IX,IY
	LD	(S11_CHANNEL),A
	LD	(S11_SEND_POINTER),HL
	LD	(S11_SEND_REMAINING),BC
	LD	HL,0
	LD	(S11_SEND_CONFIRMED),HL
	LD	A,(S11_CHANNEL)
	CALL	SELECT_CONTEXT
	JP	C,.SEND_RETURN
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_ESTABLISHED
	JP	Z,.SEND_STATE_OK
	CP	TCP_STATE_CLOSE_WAIT
	JP	NZ,.SEND_CLOSED
.SEND_STATE_OK
	LD	HL,(S11_SEND_REMAINING)
	LD	A,H
	OR	L
	JP	Z,.SEND_OK_SELECTED
	LD	HL,(S11_SEND_POINTER)
	LD	BC,(S11_SEND_REMAINING)
	CALL	@IPV4.VALIDATE_REGION
	JP	C,.SEND_PARAMETER
.SEND_NEXT
	LD	HL,(S11_SEND_REMAINING)
	LD	A,H
	OR	L
	JP	Z,.SEND_OK_SELECTED
	CALL	WAIT_REMOTE_WINDOW
	JP	C,.SEND_FAIL
	LD	A,TCP_STAGE_DATA
	LD	(S11_DIAG_STAGE),A
	IFDEF	TCPX_SEND_BURST
	CALL	CHOOSE_BURST
	ELSE
	CALL	CHOOSE_SEGMENT_LENGTH
	LD	HL,(S11_SEGMENT_LENGTH)
	LD	(S11_ACTIVE_LENGTH),HL
	IFNDEF	UNET_DLL
	LD	HL,(S11_SEND_POINTER)
	LD	DE,TCPX_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	LD	BC,(S11_ACTIVE_LENGTH)
	LDIR
	ENDIF
	ENDIF
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	LD	DE,S11_TARGET_ACK
	CALL	COPY4
	IFDEF	TCPX_SEND_BURST
	; SND.NXT still equals SND.UNA here -- .DATA_EVENT only advances on an
	; acknowledgement of everything outstanding -- so the copy just made is
	; the burst's first sequence number, and the second segment's is one
	; segment further on. Built once per burst rather than per retransmission.
	LD	HL,S11_TARGET_ACK
	LD	DE,S11_BURST_SEQ
	CALL	COPY4
	LD	HL,S11_BURST_SEQ
	LD	DE,(S11_BURST_FIRST)
	CALL	ADD16_TO32
	ENDIF
	LD	HL,S11_TARGET_ACK
	LD	DE,(S11_ACTIVE_LENGTH)
	CALL	ADD16_TO32
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	EX	DE,HL
	LD	HL,S11_TARGET_ACK
	CALL	COPY4
	LD	(IX+CTX_RETRY_LEFT),DATA_ATTEMPTS
.DATA_TRY
	LD	A,(IX+CTX_EVENT)
	AND	~(EVENT_ACK|EVENT_RST|EVENT_FIN)
	LD	(IX+CTX_EVENT),A
	IFDEF	UNET_DLL
	; Re-copy the payload from the caller's own buffer before every
	; attempt, not just the first (SEND_WINDOW_PROBE already does the same
	; for its own 1-byte probe -- see its own comment): TCPX_TX_BUFFER
	; aliases the RX buffer, and inbound frames read during the waits
	; below (any channel) may have overwritten it since the last attempt.
	LD	HL,(S11_SEND_POINTER)
	LD	DE,TCPX_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	LD	BC,(S11_ACTIVE_LENGTH)
	LDIR
	ENDIF
	IFDEF	TCPX_SEND_BURST
	CALL	SEND_BURST
	ELSE
	LD	A,TCP_FLAG_PSH|TCP_FLAG_ACK
	LD	BC,(S11_ACTIVE_LENGTH)
	CALL	SEND_SEGMENT
	ENDIF
	IFDEF	UNET_DLL
	JP	C,.SEND_FAIL_XMIT
	ELSE
	JP	C,.SEND_FAIL
	ENDIF
	LD	A,(IX+CTX_RETRY_LEFT)
	CALL	ATTEMPT_MS
.DATA_ATTEMPT_MS
	IFDEF	TCPX_ASYNCSEND
	LD	(S11_ASYNC_MS_LEFT),BC
.DATA_WAIT
	; Quantum for this wait: the whole remaining attempt budget when
	; blocking (UNET_OPT_SLICE=0, byte-identical to the non-ASYNCSEND
	; behavior below), or the smaller of the remaining budget and the
	; slice when the caller armed UNET_OPT_SENDSLICE.
	LD	HL,(S11_ASYNC_MS_LEFT)
	LD	DE,(UNET_OPT_SLICE)
	LD	A,D
	OR	E
	JR	Z,.DATA_QUANTUM_READY
	OR	A
	SBC	HL,DE
	JR	NC,.DATA_QUANTUM_READY
	ADD	HL,DE			; remaining < slice: use remaining as-is
.DATA_QUANTUM_READY
	LD	B,H
	LD	C,L
	; The quantum is kept on the stack, not trusted to survive the wait in
	; BC: the receive poll and the tick pacing both leave BC=0. Charged as
	; zero, a silent attempt never ran out, and a blocking SEND (slice 0)
	; suspended with TCP_ERR_AGAIN after its first quiet second -- leaving
	; CLOSE/NETDONE answering NERR_BUSY to a caller that never asked for a
	; resumable send.
	PUSH	BC
	LD	A,EVENT_ACK|EVENT_FIN|EVENT_RST
	CALL	WAIT_FOR_EVENT
	POP	BC
	JP	NC,.DATA_EVENT
	CP	TCP_ERR_TIMEOUT
	JP	NZ,.SEND_FAIL
	; WAIT_FOR_EVENT only returns F_TIMEOUT after waiting its full
	; requested quantum, so BC is exactly the elapsed silence.
	LD	HL,(S11_ASYNC_MS_LEFT)
	OR	A
	SBC	HL,BC
	LD	(S11_ASYNC_MS_LEFT),HL
	LD	A,H
	OR	L
	JP	Z,.DATA_ATTEMPT_EXHAUSTED
	; Silence within the attempt but budget remains: suspend without
	; burning a retry or retransmitting. SEND_RESUME re-enters .DATA_WAIT
	; directly for this same outstanding segment.
	JP	.SEND_AGAIN
.DATA_ATTEMPT_EXHAUSTED
	ELSE
.DATA_WAIT
	LD	A,EVENT_ACK|EVENT_FIN|EVENT_RST
	CALL	WAIT_FOR_EVENT
	JP	NC,.DATA_EVENT
	CP	TCP_ERR_TIMEOUT
	JP	NZ,.SEND_FAIL
	ENDIF
	LD	A,(IX+CTX_RETRY_LEFT)
	DEC	A
	LD	(IX+CTX_RETRY_LEFT),A
	JP	NZ,.DATA_TRY
	LD	A,TCP_ERR_TIMEOUT
	JP	.SEND_FAIL
.DATA_EVENT
	BIT	3,A
	JP	NZ,.SEND_RESET
	IFDEF	UNET_DLL
	; The cold classifier distinguishes a full ACK from FIN-before-full-ACK
	; and computes the latter's partial progress. It does not release the
	; context: peer payload and REMOTE_FIN must remain visible to RECV.
	LD	IY,S11_STATE_BASE
	LD	A,CFN_TCP_SEND_EVENT
	CALL	@COLD.RUN
	JP	C,.SEND_PEER_FIN
	JP	NZ,.SEND_FAIL
	ELSE
	PUSH	IX
	POP	DE
	LD	HL,CTX_SND_UNA
	ADD	HL,DE
	LD	DE,S11_TARGET_ACK
	CALL	CMP4
	LD	A,TCP_ERR_SEQUENCE
	JP	NZ,.SEND_FAIL
	ENDIF
	LD	HL,(S11_SEND_POINTER)
	LD	DE,(S11_ACTIVE_LENGTH)
	ADD	HL,DE
	LD	(S11_SEND_POINTER),HL
	LD	HL,(S11_SEND_REMAINING)
	OR	A
	SBC	HL,DE
	LD	(S11_SEND_REMAINING),HL
	LD	HL,(S11_SEND_CONFIRMED)
	ADD	HL,DE
	LD	(S11_SEND_CONFIRMED),HL
	JP	.SEND_NEXT
	IFDEF	UNET_DLL
.SEND_PEER_FIN
	; TCP_SEND_EVENT already returned TCP_ERR_CLOSED and the exact confirmed
	; prefix in DE. Bypass FAIL_CONTEXT so queued response bytes survive.
	SCF
	JP	.SEND_RETURN
	ENDIF
	IFDEF	UNET_DLL
.SEND_FAIL_XMIT
	; A segment that never left the card on the FIRST attempt leaves nothing
	; past SND.UNA in flight, so a later CLOSE of this still-open connection
	; is an orderly FIN. A retransmission that fails is different: the earlier
	; attempt did go out and only its ACK is missing, so whether the peer took
	; the bytes is unknowable and SND.NXT stays past them for CLOSE to abort.
	; (UNETRTL 0.3.10 rewinds on every attempt; that is the one deliberate
	; divergence from it, see docs/UNET509B.md.)
	PUSH	AF
	LD	A,(IX+CTX_RETRY_LEFT)
	CP	DATA_ATTEMPTS
	JR	NZ,.SEND_FAIL_POP
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_UNA
	ADD	HL,DE
	LD	D,H
	LD	E,L
	INC	DE
	INC	DE
	INC	DE
	INC	DE			; SND.NXT follows SND.UNA
	CALL	COPY4
.SEND_FAIL_POP
	POP	AF
	JR	.SEND_FAIL
	ENDIF
.SEND_RESET
	LD	A,TCP_ERR_RESET
.SEND_FAIL
	IFNDEF	UNET_DLL
	PUSH	AF
	CALL	FAIL_CONTEXT
	POP	AF
	ELSE
	; The DLL leaves the connection as the failure found it, as UNETRTL does.
	; A peer RST already closed the context (HANDLE_SEGMENT .ACCEPT_RST); a
	; timeout or a cancel leaves it established with SND.NXT past the
	; unacknowledged segment, so the caller's CLOSE resets the peer instead of
	; sending a FIN it cannot sequence, or finding nothing left to tell it.
	ENDIF
	LD	DE,(S11_SEND_CONFIRMED)
	SCF
	JP	.SEND_RETURN
	IFDEF	TCPX_ASYNCSEND
; Not a failure: the segment (or window probe) is still legitimately in
; flight. FAIL_CONTEXT must NOT run here -- the context stays exactly as
; it is so SEND_RESUME can continue waiting on the SAME outstanding
; segment/probe.
.SEND_AGAIN
	LD	A,TCP_ERR_AGAIN
	LD	DE,(S11_SEND_CONFIRMED)
	SCF
	JP	.SEND_RETURN
	ENDIF
.SEND_CLOSED
	LD	A,TCP_ERR_CLOSED
	LD	DE,0
	SCF
	JP	.SEND_RETURN
.SEND_PARAMETER
	LD	A,NETDRV_ERR_PARAMETER
	LD	DE,0
	SCF
	JP	.SEND_RETURN
.SEND_OK_SELECTED
	LD	DE,(S11_SEND_CONFIRMED)
	XOR	A
.SEND_RETURN
	POP	IY,IX
	RET

	IFDEF	TCPX_ASYNCSEND
; SEND_RESUME: continue a SEND suspended with TCP_ERR_AGAIN. In: A=channel
; (the shim's own resume-contract check already confirmed this matches the
; suspended one). Re-enters SEND's own ACK wait directly for the same
; outstanding segment -- neither resends nor burns a retry (the window-
; probe wait is never sliced, so a suspend can only ever be pending there).
; Out/clobbers: same as SEND.
SEND_RESUME
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,SEND.SEND_RETURN
	JP	SEND.DATA_WAIT
	ENDIF

; RECV
; In: A=channel, HL=destination, BC=capacity, DE=timeout milliseconds.
; Out: BC=bytes copied. Timeout, orderly close and reset are distinct statuses.
; Clobbers AF/DE/HL; preserves IX/IY.
RECV
	PUSH	IX,IY
	LD	(S11_CHANNEL),A
	LD	(S11_SEND_POINTER),HL
	LD	(S11_COPY_LENGTH),BC
	LD	(S11_TIMEOUT_MS),DE
	LD	A,B
	OR	C
	JP	Z,.RECV_PARAMETER
	CALL	@IPV4.VALIDATE_REGION
	JP	C,.RECV_PARAMETER
	LD	A,(S11_CHANNEL)
	CALL	SELECT_CONTEXT
	JP	NC,.RECV_SELECTED
	LD	BC,0
	JP	.RECV_RETURN
.RECV_SELECTED
	IFDEF EL3_SESSION_RX
	LD	HL,(S11_SEND_POINTER)
	LD	(S11_RX_DEST),HL
	LD	HL,(S11_COPY_LENGTH)
	LD	(S11_RX_FREE),HL
	XOR	A
	LD	L,A
	LD	H,A
	LD	(S11_RX_DELIVERED),HL
	IFNDEF TCPX_WIDE_DIRECT_WINDOW
	LD	(S11_FAST_LENGTH),A	; direct-segment count in this RECV scope
	ENDIF
	ENDIF
.RECV_CHECK
	LD	L,(IX+CTX_PENDING_LEN)
	LD	H,(IX+CTX_PENDING_LEN+1)
	LD	A,H
	OR	L
	JP	NZ,.RECV_COPY
	LD	A,(IX+CTX_REMOTE_FIN)
	OR	A
	JP	NZ,.RECV_CLOSED
	LD	A,(IX+CTX_STATE)
	OR	A
	JP	Z,.RECV_STATE_ERROR
	LD	A,(IX+CTX_EVENT)
	AND	~(EVENT_DATA|EVENT_FIN|EVENT_RST)
	LD	(IX+CTX_EVENT),A
	LD	A,EVENT_DATA|EVENT_FIN|EVENT_RST
	PUSH	AF
	LD	A,TCP_STAGE_RECV
	LD	(S11_DIAG_STAGE),A
	POP	AF
	LD	BC,(S11_TIMEOUT_MS)
	IFDEF	EL3_SESSION_RX
	; The scope was opened once at .RECV_SELECTED and remains active while
	; pending bytes and several FIFO segments fill the same caller buffer.
	CALL	WAIT_FOR_EVENT
	PUSH	AF
	LD	BC,(S11_RX_DELIVERED)
	LD	A,B
	OR	C
	JR	Z,.RECV_NO_DIRECT
	POP	AF			; bytes already in the caller's buffer
	XOR	A			; outrank the wait's own status: a close,
	JP	.RECV_RETURN		; a reset or a timeout is still there to
					; be found by the next call, they are not
.RECV_NO_DIRECT
	POP	AF
	ELSE
	CALL	WAIT_FOR_EVENT
	ENDIF
	JP	C,.RECV_RETURN
	BIT	3,A
	JP	NZ,.RECV_RESET
	JP	.RECV_CHECK
.RECV_COPY
	IFDEF EL3_SESSION_RX
	LD	DE,(S11_RX_DELIVERED)
	LD	HL,(S11_RX_FREE)
	OR	A
	SBC	HL,DE			; remaining caller capacity
	EX	DE,HL
	ELSE
	LD	DE,(S11_COPY_LENGTH)
	ENDIF
	LD	L,(IX+CTX_PENDING_LEN)
	LD	H,(IX+CTX_PENDING_LEN+1)
	OR	A
	SBC	HL,DE
	JP	C,.CAPACITY_SMALLER
	JP	Z,.CAPACITY_SMALLER
	LD	H,D
	LD	L,E			; pending is larger: copy remaining capacity
	JP	.COPY_READY
.CAPACITY_SMALLER
	ADD	HL,DE
.COPY_READY
	LD	(S11_COPY_LENGTH),HL
	CALL	PENDING_BASE
	LD	L,(IX+CTX_PENDING_OFF)
	LD	H,(IX+CTX_PENDING_OFF+1)
	ADD	HL,DE
	IFDEF EL3_SESSION_RX
	LD	DE,(S11_RX_DEST)
	PUSH	HL
	LD	HL,(S11_RX_DELIVERED)
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	ELSE
	LD	DE,(S11_SEND_POINTER)
	ENDIF
	LD	BC,(S11_COPY_LENGTH)
	LDIR
	LD	HL,(S11_COPY_LENGTH)
	LD	E,(IX+CTX_PENDING_OFF)
	LD	D,(IX+CTX_PENDING_OFF+1)
	ADD	HL,DE
	LD	(IX+CTX_PENDING_OFF),L
	LD	(IX+CTX_PENDING_OFF+1),H
	LD	L,(IX+CTX_PENDING_LEN)
	LD	H,(IX+CTX_PENDING_LEN+1)
	LD	DE,(S11_COPY_LENGTH)
	OR	A
	SBC	HL,DE
	LD	(IX+CTX_PENDING_LEN),L
	LD	(IX+CTX_PENDING_LEN+1),H
	LD	A,H
	OR	L
	JP	NZ,.RECV_SUCCESS
	XOR	A
	LD	(IX+CTX_PENDING_OFF),A
	LD	(IX+CTX_PENDING_OFF+1),A
	IFDEF EL3_SESSION_RX
	LD	HL,(S11_RX_DELIVERED)
	LD	DE,(S11_COPY_LENGTH)
	ADD	HL,DE
	LD	(S11_RX_DELIVERED),HL
	LD	A,(IX+CTX_REMOTE_FIN)
	OR	A
	JR	NZ,.RECV_SUCCESS	; deliver the FIN-bearing tail before close
	LD	DE,(S11_RX_FREE)
	EX	DE,HL
	OR	A
	SBC	HL,DE			; remaining capacity
	LD	DE,TCP_MSS
	OR	A
	SBC	HL,DE			; CF: no whole segment can be promised
	; The window-closed latch is settled *before* that decision is acted on.
	; A latched close means the peer is stopped on a zero window and only an
	; update sent from here restarts it, and that is true whether or not this
	; RECV has room for another segment. Acting on the room first, as this
	; used to, dropped the update whenever the caller's buffer filled on the
	; very drain that emptied the queue -- and then the next RECV waited on a
	; peer that was waiting on us. FTP's one-segment RECV met it on the first
	; two segments, which had queued up while it was still reading the "150"
	; reply. BIT leaves CF alone, so the room verdict survives the send.
	BIT	0,(IX+CTX_WINDOW_CLOSED)
	JR	Z,.RECV_ROOM_DECIDED
	PUSH	AF
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT		; best-effort window update
	POP	AF
.RECV_ROOM_DECIDED
	JR	C,.RECV_SUCCESS
	JP	.RECV_CHECK
	ELSE
	IFDEF	STAGE12_LAYOUT
	; A multi-segment window only closes once the pending region is full,
	; so draining it does not by itself mean the peer is blocked. Spend the
	; extra round trip on a window update only when we really did advertise
	; zero; SEND_SEGMENT_COMMON below clears the latch as it reopens.
	BIT	0,(IX+CTX_WINDOW_CLOSED)
	JP	Z,.RECV_SUCCESS
	ELSE
	; The one-MSS window closes on every accepted segment, so a drained
	; pending slot always means the window just reopened from zero.
	ENDIF
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT		; best-effort window update
	ENDIF
.RECV_SUCCESS
	IFDEF EL3_SESSION_RX
	; Account for the final chunk if pending remains; the empty-pending path
	; above already added it before deciding whether another MSS could fit.
	LD	A,(IX+CTX_PENDING_LEN)
	OR	(IX+CTX_PENDING_LEN+1)
	JR	Z,.RECV_TOTAL_READY
	LD	HL,(S11_RX_DELIVERED)
	LD	DE,(S11_COPY_LENGTH)
	ADD	HL,DE
	LD	(S11_RX_DELIVERED),HL
.RECV_TOTAL_READY
	LD	BC,(S11_RX_DELIVERED)
	IFNDEF TCPX_WIDE_DIRECT_WINDOW
	LD	HL,S11_ACK_OWED		; publish the final ACK for this buffer drain
	INC	(HL)			; even if the last threshold ACK just settled it
	ENDIF
	ELSE
	LD	BC,(S11_COPY_LENGTH)
	ENDIF
	XOR	A
	JR	.RECV_RETURN
.RECV_PARAMETER
	LD	A,NETDRV_ERR_PARAMETER
	LD	BC,0
	SCF
	JP	.RECV_RETURN
.RECV_CLOSED
	LD	A,TCP_ERR_CLOSED
	LD	BC,0
	SCF
	JP	.RECV_RETURN
; .RECV_STATE_ERROR is reached with no pending data, no FIN seen, and the
; context already closed. That happens for a plain orderly close (CTX_STATE
; was cleared with nothing more specific to say -- CLEAR_CONTEXT zeroes
; CTX_LAST_STATUS along with the rest, and no real TCP_ERR_*/NETDRV_ERR_*
; code is ever 0) but also for a RST that HANDLE_SEGMENT's ACCEPT_RST
; recorded and closed the context for *before* this call, e.g. one that
; arrived while the caller was busy waiting on the other channel's own
; WAIT_FOR_EVENT rather than this one's. Reporting a blanket TCP_ERR_CLOSED
; either way lets a genuinely reset, truncated transfer look like an
; orderly one; CTX_LAST_STATUS already remembers which it was.
.RECV_STATE_ERROR
	LD	A,(IX+CTX_LAST_STATUS)
	OR	A
	JR	NZ,.RECV_LAST_STATUS
	LD	A,TCP_ERR_CLOSED
.RECV_LAST_STATUS
	LD	BC,0
	SCF
	JP	.RECV_RETURN
.RECV_RESET
	LD	A,TCP_ERR_RESET
	LD	BC,0
	SCF
.RECV_RETURN
	IFDEF EL3_SESSION_RX
	; Close direct access to the caller before the final cumulative ACK. The DLL
	; then advertises only durable pending capacity; DLDIRECT's explicit wider
	; profile remains backed by the on-card RX FIFO across the short boundary.
	PUSH	AF,BC
	LD	HL,0
	LD	(S11_RX_FREE),HL
	CALL	SEND_OWED_ACK
	XOR	A
	LD	L,A
	LD	H,A
	LD	(S11_RX_DELIVERED),HL
	POP	BC,AF
	ENDIF
	POP	IY,IX
	RET

	IFDEF	UNET_DLL
; CLOSE ends the channel's connection and reports whether the peer was told,
; the way UNETRTL does: a FIN that merely reached the NIC proves nothing, and
; an application retrying a transfer at once needs the old one really gone.
; The cold planner (unet509b_cold.asm TCP_CLOSE_PLAN) picks the close:
;   nothing on the wire for a closed or listening context;
;   an orderly FIN when everything sent was acknowledged, retransmitted with
;   the same sequence number before the 2nd and 3rd CLOSE_ACK_TIMEOUT_MS wait;
;   an abort otherwise -- one RST|ACK at SND.NXT and one at SND.UNA, both
;   always attempted, no FIN.
; Only an ACK of exactly our FIN raises EVENT_ACK (HANDLE_SEGMENT), and a
; peer FIN or RST is an answer too; data or an older ACK keeps waiting, and a
; frame for the other channel is queued for it by PROCESS_FRAME.
; In: A=channel. Out: CF=0/A=0 answered, or nothing needed sending.
; CF=1: A=TCP_ERR_TIMEOUT when no attempt was answered (a receive-side card
; error during the wait is reported the same way: the peer said nothing we
; saw), NETDRV_ERR_CANCELLED when the user ended the wait, anything else a
; FIN or RST that never left the card. No RST follows an unanswered FIN. The
; context is released on every exit. Clobbers AF/BC/DE/HL; preserves IX/IY.
CLOSE
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JR	C,.CLOSE_RETURN
	LD	IY,S11_STATE_BASE
	LD	A,CFN_TCP_CLOSE_PLAN
	CALL	@COLD.RUN		; A=flags, BC=0
	JR	C,.CLOSE_OK
	CP	TCP_FLAG_FIN|TCP_FLAG_ACK
	JR	NZ,.CLOSE_ABORT
	CALL	SEND_SEGMENT
	JR	C,.CLOSE_FAIL
.CLOSE_WAIT
	LD	A,EVENT_ACK|EVENT_FIN|EVENT_RST
	LD	BC,CLOSE_ACK_TIMEOUT_MS
	CALL	WAIT_FOR_EVENT
	; An error exit of the wait can leave IX on whatever context the last
	; frame matched -- the other channel's -- and everything below, the
	; retry counter and CLEAR_CONTEXT included, addresses through IX.
	LD	IX,(S11_SELECTED_CONTEXT)
	JR	NC,.CLOSE_OK
	CP	TCP_ERR_TIMEOUT
	JR	NZ,.CLOSE_NOT_SILENT
	DEC	(IX+CTX_RETRY_LEFT)	; CF and A=TIMEOUT survive
	JR	Z,.CLOSE_FAIL
	LD	A,TCP_FLAG_FIN|TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT		; a lost retransmission is just silence
	JR	.CLOSE_WAIT
.CLOSE_NOT_SILENT
	CP	NETDRV_ERR_CANCELLED
	JR	Z,.CLOSE_FAIL
	LD	A,TCP_ERR_TIMEOUT
	JR	.CLOSE_FAIL
.CLOSE_ABORT
	CALL	SEND_SEGMENT_COMMON	; RST at SND.NXT, staged in TARGET_ACK
	PUSH	AF
	LD	A,TCP_FLAG_RST|TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT		; RST at SND.UNA, rewound into SND.NXT
	POP	BC			; B/C = the first RST's A/flags
	JR	C,.CLOSE_FAIL
	LD	A,B
	BIT	0,C
	JR	Z,.CLOSE_OK
.CLOSE_FAIL
	SCF
	PUSH	AF
	CALL	CLEAR_CONTEXT
	POP	AF
	JR	.CLOSE_RETURN
.CLOSE_OK
	CALL	CLEAR_CONTEXT
	XOR	A
.CLOSE_RETURN
	POP	IY,IX
	RET
	ELSE
; CLOSE performs an active close with a finite five-second wait. It is
; idempotent for an already closed channel.
; In: A=channel. Out: CF/A status. Clobbers AF/BC/DE/HL; preserves IX/IY.
CLOSE
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,.CLOSE_RETURN
	LD	A,(IX+CTX_STATE)
	OR	A
	JP	Z,.CLOSE_OK
	CP	TCP_STATE_SYN_SENT
	JP	Z,.CLOSE_ABORT
	LD	A,(IX+CTX_EVENT)
	AND	~(EVENT_ACK|EVENT_FIN|EVENT_RST)
	LD	(IX+CTX_EVENT),A
	LD	A,TCP_FLAG_FIN|TCP_FLAG_ACK
	PUSH	AF
	LD	A,TCP_STAGE_CLOSE
	LD	(S11_DIAG_STAGE),A
	POP	AF
	LD	BC,0
	CALL	SEND_SEGMENT
	JP	C,.CLOSE_FAIL
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	CALL	INC32
	LD	(IX+CTX_STATE),TCP_STATE_FIN_WAIT
	LD	A,(IX+CTX_REMOTE_FIN)
	OR	A
	JP	NZ,.CLOSE_WAIT_ACK
	LD	A,EVENT_ACK|EVENT_FIN|EVENT_RST
	LD	BC,FIN_TIMEOUT_MS
	CALL	WAIT_FOR_ALL_EVENTS
	JP	.CLOSE_WAIT_DONE
.CLOSE_WAIT_ACK
	LD	A,EVENT_ACK|EVENT_RST
	LD	BC,FIN_TIMEOUT_MS
	CALL	WAIT_FOR_EVENT
.CLOSE_WAIT_DONE
	JP	C,.CLOSE_FAIL
	BIT	3,A
	JP	NZ,.CLOSE_RESET
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_UNA
	ADD	HL,DE
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.CLOSE_FAIL_TIMEOUT
.CLOSE_OK
	CALL	CLEAR_CONTEXT
	XOR	A
	JP	.CLOSE_RETURN
.CLOSE_ABORT
	CALL	ABORT_CONTEXT
	XOR	A
	JP	.CLOSE_RETURN
.CLOSE_RESET
	LD	A,TCP_ERR_RESET
	JP	.CLOSE_FAIL
.CLOSE_FAIL_TIMEOUT
	LD	A,TCP_ERR_TIMEOUT
.CLOSE_FAIL
	PUSH	AF
	CALL	ABORT_CONTEXT
	POP	AF
	SCF
	JP	.CLOSE_RETURN
.CLOSE_RETURN
	POP	IY,IX
	RET
	ENDIF

; ABORT emits a best-effort RST for an active channel and always releases it.
; In: A=channel. Out: CF/A status. Clobbers AF/BC/DE/HL; preserves IX/IY.
ABORT
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,.ABORT_RETURN
	CALL	ABORT_CONTEXT
	XOR	A
.ABORT_RETURN
	POP	IY,IX
	RET

	IFDEF	TCPX_LISTEN
; LISTEN arms a channel for exactly one inbound connection. In: A=channel,
; HL=local port (host order, already validated nonzero by the shim). Out:
; CF/A status. Clobbers AF/BC/DE/HL; preserves IX/IY.
LISTEN
	PUSH	IX,IY
	PUSH	HL			; neither helper below leaves the port alone:
					; SELECT_CONTEXT returns the context address
					; in HL, and CLEAR_CONTEXT walks HL to the end
					; of the region it zeroes. Bound with the
					; leftover, the listener sits on an address-
					; shaped port no peer will ever address, and
					; nothing reports it -- LISTEN, STATUS and
					; UNLISTEN all still behave, every SYN just
					; misses PROCESS_FRAME's destination-port test
					; and the accept never happens.
	CALL	SELECT_CONTEXT
	JP	C,.LISTEN_BAD
	CALL	CLEAR_CONTEXT
	POP	HL
	LD	(IX+CTX_LOCAL_PORT),L
	LD	(IX+CTX_LOCAL_PORT+1),H
	LD	(IX+CTX_STATE),TCP_STATE_LISTEN
	XOR	A
	JR	.LISTEN_RETURN
.LISTEN_BAD
	POP	DE			; discard the saved port; A/CF already set
.LISTEN_RETURN
	POP	IY,IX
	RET

; UNLISTEN stops a channel TCPX.LISTEN armed: RST only if a peer's
; handshake is in flight (SYN_RECEIVED), otherwise just clears the
; context. In: A=channel. Out: CF/A status. Clobbers AF/BC/DE/HL;
; preserves IX/IY.
UNLISTEN
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,.UNLISTEN_RETURN
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_SYN_RECEIVED
	JR	NZ,.UNLISTEN_CLEAR
	LD	A,TCP_FLAG_RST|TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT
.UNLISTEN_CLEAR
	CALL	CLEAR_CONTEXT
	XOR	A
.UNLISTEN_RETURN
	POP	IY,IX
	RET

; ACCEPT_POLL waits up to BC ms for the bound channel's handshake to
; finish. In: A=channel, BC=timeout ms. Out: A=1 established, A=0 idle
; (timeout, or the peer reset -- LISTEN is already re-armed by then).
; Clobbers AF/BC/DE/HL; preserves IX/IY.
ACCEPT_POLL
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,.ACCEPT_IDLE
	LD	A,(IX+CTX_EVENT)
	AND	~(EVENT_SYN_ACK|EVENT_RST)
	LD	(IX+CTX_EVENT),A
	LD	A,EVENT_SYN_ACK|EVENT_RST
	CALL	WAIT_FOR_EVENT
	JR	C,.ACCEPT_IDLE
	BIT	3,A
	JR	NZ,.ACCEPT_IDLE
	LD	A,1
	JR	.ACCEPT_RETURN
.ACCEPT_IDLE
	XOR	A
.ACCEPT_RETURN
	POP	IY,IX
	RET
	ENDIF

	IFNDEF STAGE12_LAYOUT	; WGET reports through its own diagnostics
; STATUS: In A=channel. Out A=TCP_STATE_*, B=last status, CF clear.
; Invalid channel returns NETDRV_ERR_PARAMETER/CF set. Clobbers AF/B/HL;
; preserves C/DE/IX/IY.
STATUS
	PUSH	IX,IY
	CALL	SELECT_CONTEXT
	JP	C,.STATUS_RETURN
	LD	B,(IX+CTX_LAST_STATUS)
	LD	A,(IX+CTX_STATE)
	OR	A
.STATUS_RETURN
	POP	IY,IX
	RET
	ENDIF

SELECT_CONTEXT
	IFDEF	TCPX_SINGLE_CONTEXT
	OR	A
	JP	NZ,.BAD
	LD	(S11_CHANNEL),A
	LD	IX,S11_CONTEXT0
	ELSE
	CP	2
	JP	NC,.BAD
	LD	(S11_CHANNEL),A
	OR	A
	LD	IX,S11_CONTEXT0
	JP	Z,.STORE
	LD	IX,S11_CONTEXT1
.STORE
	ENDIF
	PUSH	IX
	POP	HL
	LD	(S11_SELECTED_CONTEXT),HL
	XOR	A
	RET
.BAD
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

CLEAR_CONTEXT
	PUSH	IX
	POP	HL
	LD	BC,S11_CONTEXT_SIZE
	JP	ZERO_REGION

ZERO_REGION
	LD	A,B
	OR	C
	RET	Z
.ZERO
	XOR	A
	LD	(HL),A
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JP	NZ,.ZERO
	RET

GENERATE_TUPLE
	LD	HL,(S11_NEXT_LOCAL_PORT)
	LD	(IX+CTX_LOCAL_PORT),L
	LD	(IX+CTX_LOCAL_PORT+1),H
	INC	HL
	LD	A,H
	OR	L
	JP	NZ,.NEXT_PORT_READY
	LD	HL,0xC000
.NEXT_PORT_READY
	LD	(S11_NEXT_LOCAL_PORT),HL
	CALL	@S9APP.SECONDS
	LD	(IX+CTX_SND_UNA),A
	LD	A,R
	LD	(IX+CTX_SND_UNA+1),A
	XOR	(IX+CTX_REMOTE_IP+3)
	LD	(IX+CTX_SND_UNA+2),A
	LD	A,R
	XOR	(IX+CTX_LOCAL_PORT)
	LD	(IX+CTX_SND_UNA+3),A
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_UNA
	ADD	HL,DE
	PUSH	HL
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	EX	DE,HL
	POP	HL
	CALL	COPY4
	RET

; Resolve the selected context's next hop with three finite ARP attempts.
RESOLVE_ROUTE
	PUSH	IX
	POP	HL
	LD	DE,CTX_REMOTE_IP
	ADD	HL,DE
	CALL	@ARP.SELECT_NEXT_HOP
	RET	C
	OR	A
	JP	NZ,.BAD_TARGET
	CALL	@S9APP.SECONDS
	LD	C,A
	LD	B,0
	LD	HL,NET_NEXT_HOP_IP
	IFDEF	UNET_DLL
	; No ARP cache in the DLL (plan decision #6): one exchange per operation.
	SCF
	ELSE
	CALL	@ARP.CACHE_LOOKUP
	ENDIF
	RET	NC
	LD	(IX+CTX_RETRY_LEFT),ARP_ATTEMPTS
.ARP_TRY
	LD	DE,TCPX_TX_BUFFER
	LD	HL,NET_NEXT_HOP_IP
	CALL	@ARP.BUILD_REQUEST
	LD	HL,TCPX_TX_BUFFER
	CALL	@NETDRV.SEND_FRAME
	RET	C
	; The first request after the driver comes up is the one that gets lost:
	; The requests a freshly initialised card sends are dropped in the path
	; and heal within about a second, so the opening attempts ask again
	; quickly instead of waiting out the documented deadline -- the schedule
	; and its evidence are in netdrv.inc.
	LD	A,(IX+CTX_RETRY_LEFT)
	CP	ARP_FAST_LEFT
	LD	BC,ARP_FIRST_MS
	JR	NC,.ARP_ARM
	LD	BC,ARP_TIMEOUT_MS
.ARP_ARM
	CALL	@NETTIME.START
	RET	C
.ARP_POLL
	CALL	CHECK_CANCEL
	RET	C
	CALL	@NETDRV.RX_PENDING
	RET	C
	OR	A
	JP	Z,.ARP_TICK
	LD	HL,STAGE9_RX_BUFFER
	LD	BC,STAGE9_RX_CAPACITY
	CALL	@NETDRV.READ_FRAME
	JP	C,.ARP_TICK
	LD	HL,STAGE9_RX_BUFFER
	CALL	@ARP.PARSE
	JP	C,.ARP_TICK
	CP	1
	JP	Z,.ARP_FOUND
	CP	2
	JP	NZ,.ARP_TICK
	LD	DE,STAGE9_TX_BUFFER
	LD	HL,STAGE9_RX_BUFFER
	CALL	@ARP.BUILD_REPLY
	LD	HL,STAGE9_TX_BUFFER
	CALL	@NETDRV.SEND_FRAME
	RET	C
.ARP_TICK
	CALL	@NETTIME.TICK
	JP	NC,.ARP_POLL
	LD	A,(IX+CTX_RETRY_LEFT)
	DEC	A
	LD	(IX+CTX_RETRY_LEFT),A
	JP	NZ,.ARP_TRY
	LD	A,TCP_ERR_TIMEOUT
	SCF
	RET
.ARP_FOUND
	IFDEF	UNET_DLL
	; No ARP cache in the DLL (plan decision #6); CF is already clear here.
	RET
	ELSE
	CALL	@S9APP.SECONDS
	LD	C,A
	LD	B,0
	LD	HL,NET_NEXT_HOP_IP
	LD	DE,NET_RESULT_MAC
	CALL	@ARP.CACHE_INSERT
	RET
	ENDIF
.BAD_TARGET
	LD	A,NETDRV_ERR_PARAMETER
	SCF
	RET

CHOOSE_SEGMENT_LENGTH
	LD	HL,(S11_SEND_REMAINING)
	LD	E,(IX+CTX_PEER_MSS)
	LD	D,(IX+CTX_PEER_MSS+1)
	OR	A
	SBC	HL,DE
	JP	C,.REMAINING_SMALLER
	JP	Z,.REMAINING_SMALLER
	EX	DE,HL
	JP	.MSS_READY
.REMAINING_SMALLER
	ADD	HL,DE
.MSS_READY
	LD	E,(IX+CTX_REMOTE_WINDOW)
	LD	D,(IX+CTX_REMOTE_WINDOW+1)
	PUSH	HL
	OR	A
	SBC	HL,DE
	POP	HL
	JP	C,.CHOSEN
	JP	Z,.CHOSEN
	EX	DE,HL
.CHOSEN
	LD	(S11_SEGMENT_LENGTH),HL
	RET

	IFDEF	TCPX_SEND_BURST
; CHOOSE_BURST picks how much of the caller's buffer this round trip carries:
; one segment, or two whole ones back to back.
;
; One segment in flight is one segment per round trip, and on a LAN the round
; trip is not the wire, it is the peer's delayed-ACK timer: RFC 1122 lets a
; receiver hold an acknowledgement and only obliges it to answer at once "at
; least every second full-sized segment". A sender that never has two full
; segments outstanding can never satisfy that clause, so it pays the timer on
; every segment. Measured on real hardware against a NAS, upload sat at 12
; KB/s while a download over the same connection ran at 31 KB/s -- and the
; harness put the upload's cost per byte within 7% of the download's, so the
; missing time was idle, not work.
;
; The pair is deliberately all-or-nothing: two whole segments or one. A pair
; whose halves differ in length would need a second length to carry around,
; and the only round trip it would save is the last one of a transfer.
; In: IX=context, S11_SEND_REMAINING, S11_SEND_POINTER.
; Out: S11_ACTIVE_LENGTH=bytes this round trip must have acknowledged,
; S11_BURST_FIRST=first segment's length, S11_BURST_PAIR set when a second
; whole segment follows it. Clobbers AF/DE/HL.
CHOOSE_BURST
	CALL	CHOOSE_SEGMENT_LENGTH
	LD	(S11_ACTIVE_LENGTH),HL
	LD	(S11_BURST_FIRST),HL
	XOR	A
	LD	(S11_BURST_PAIR),A
	; Everything below is expressed in whole multiples of the length
	; CHOOSE_SEGMENT_LENGTH just picked, never in TCP_MSS. That constant is
	; our *receive* MSS; what bounds a segment we send is the peer's, which
	; CHOOSE_SEGMENT_LENGTH already applied (CTX_PEER_MSS). While the two
	; happened to be equal the difference was invisible -- once they differ,
	; comparing against TCP_MSS matches nothing and the pair silently never
	; forms, dropping the upload back to stop-and-wait.
	;
	; A first segment shortened by the buffer or by a squeezed window needs no
	; separate test: doubling it then fails one of the two checks below.
	ADD	HL,HL			; HL = DE = two whole first segments
	RET	C
	LD	D,H
	LD	E,L
	LD	HL,(S11_SEND_REMAINING)
	OR	A
	SBC	HL,DE
	RET	C			; fewer than two whole segments left
	; The peer must be able to hold both at once. This is now an exact 16-bit
	; compare rather than the old high-byte approximation, which only existed
	; to keep the constant form cheap.
	LD	L,(IX+CTX_REMOTE_WINDOW)
	LD	H,(IX+CTX_REMOTE_WINDOW+1)
	OR	A
	SBC	HL,DE
	RET	C
	LD	A,1
	LD	(S11_BURST_PAIR),A
	LD	(S11_ACTIVE_LENGTH),DE
	RET

; SEND_BURST copies and transmits the burst CHOOSE_BURST picked. Both segments
; are rebuilt from the caller's buffer every time, so a retransmission after a
; timeout resends exactly the same bytes; the one TX buffer serves both because
; NETDRV.SEND_FRAME has already handed the first frame to the card by the time
; the second is built.
; An acknowledgement of the first segment alone is ignored rather than acted
; on: HANDLE_SEGMENT takes an ACK only when it matches SND.NXT exactly, and
; SND.NXT covers the whole burst. So .DATA_EVENT still sees exactly one
; cumulative acknowledgement per round trip, and a pair whose second half is
; lost is retransmitted whole -- go-back-N, on the same retry ladder as before.
; In: IX=context, S11_SEND_POINTER, S11_BURST_FIRST, S11_BURST_PAIR,
; S11_BURST_SEQ (built by SEND, once per burst).
; Out: CF set with A=driver status on failure. Clobbers AF/BC/DE/HL.
SEND_BURST
	LD	HL,(S11_SEND_POINTER)
	LD	DE,STAGE9_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	LD	BC,(S11_BURST_FIRST)
	LDIR
	PUSH	HL			; LDIR left it on the second segment's bytes
	LD	BC,(S11_BURST_FIRST)
	LD	A,TCP_FLAG_PSH|TCP_FLAG_ACK
	CALL	SEND_SEGMENT
	POP	HL
	RET	C
	LD	A,(S11_BURST_PAIR)
	OR	A
	RET	Z			; single segment: CF is clear, A is zero
	LD	DE,STAGE9_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	LD	BC,(S11_BURST_FIRST)	; the pair is two equal segments, and that
	LDIR				; length came from the peer's MSS, not ours
	LD	A,SEQUENCE_FROM_BURST
	LD	(S11_SEQUENCE_OVERRIDE),A
	LD	A,TCP_FLAG_PSH|TCP_FLAG_ACK
	LD	BC,(S11_BURST_FIRST)
	JP	SEND_SEGMENT_COMMON
	ENDIF

WAIT_REMOTE_WINDOW
	LD	A,(IX+CTX_REMOTE_WINDOW)
	OR	(IX+CTX_REMOTE_WINDOW+1)
	RET	NZ
	LD	A,TCP_STAGE_WINDOW
	LD	(S11_DIAG_STAGE),A
	LD	(IX+CTX_RETRY_LEFT),3
.PROBE
	LD	A,(IX+CTX_EVENT)
	AND	~(EVENT_WINDOW|EVENT_RST|EVENT_FIN)
	LD	(IX+CTX_EVENT),A
	CALL	SEND_WINDOW_PROBE
	RET	C
	LD	A,(IX+CTX_RETRY_LEFT)
	CALL	ATTEMPT_MS
; Unlike SEND's own ACK wait, this window-probe wait is never sliced by
; TCPX_ASYNCSEND: a fully-closed remote window is rare enough that RTL's
; own ASYNCSEND does not cover it either (see this DLL's plan notes), and
; every byte here is scarce.
.PROBE_WAIT
	LD	A,EVENT_WINDOW|EVENT_RST|EVENT_FIN
	CALL	WAIT_FOR_EVENT
	JP	C,.PROBE_TIMEOUT
	BIT	3,A
	JP	NZ,.PROBE_RESET
	LD	A,(IX+CTX_REMOTE_WINDOW)
	OR	(IX+CTX_REMOTE_WINDOW+1)
	RET	NZ
.PROBE_TIMEOUT
	LD	A,(IX+CTX_RETRY_LEFT)
	DEC	A
	LD	(IX+CTX_RETRY_LEFT),A
	JP	NZ,.PROBE
	LD	A,TCP_ERR_WINDOW
	SCF
	RET
.PROBE_RESET
	LD	A,TCP_ERR_RESET
	SCF
	RET

; SEND_WINDOW_PROBE sends one already-acknowledged octet at SND.NXT-1. Unlike
; an empty ACK, this persist probe requires a conforming peer to answer without
; consuming the caller's first unsent byte.
SEND_WINDOW_PROBE
	LD	HL,(S11_SEND_POINTER)
	LD	A,(HL)
	LD	(TCPX_TX_BUFFER+14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH),A
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	LD	DE,S11_TARGET_ACK
	CALL	COPY4
	LD	HL,S11_TARGET_ACK
	CALL	DEC32
	LD	A,SEQUENCE_FROM_TARGET
	LD	(S11_SEQUENCE_OVERRIDE),A
	LD	A,TCP_FLAG_ACK
	LD	BC,1
	JP	SEND_SEGMENT_COMMON

; ATTEMPT_MS: shared by SEND's own retry ladder and WAIT_REMOTE_WINDOW's.
; In: A=(IX+CTX_RETRY_LEFT), already loaded by the caller (3/2/1 remaining).
; Out: BC=1000/2000/4000. Trashes AF.
ATTEMPT_MS
	CP	3
	LD	BC,1000
	RET	Z
	CP	2
	LD	BC,2000
	RET	Z
	LD	BC,4000
	RET

; SEND_SEGMENT builds Ethernet/IPv4/TCP contiguously and transmits it.
; In: IX=context, A=flags, BC=payload length already at TX+54.
SEND_SEGMENT
	PUSH	AF
	XOR	A			; SEQUENCE_FROM_CONTEXT
	LD	(S11_SEQUENCE_OVERRIDE),A
	POP	AF
SEND_SEGMENT_COMMON
	IFDEF UNET_DLL
	LD	D,A			; flags survive A becoming the cold function id
	PUSH	IX
	POP	IY			; selected context for the cold builder
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_TCP_IP_BUILD
	CALL	@COLD.RUN		; returns IX=context, HL=frame, BC=wire length
	RET	C
	JP	@NETDRV.SEND_FRAME
	ELSE
	LD	(S11_BUILD_FLAGS),A
	LD	(S11_SEGMENT_LENGTH),BC
	LD	HL,TCPX_TX_BUFFER+14+IPV4_HEADER_LENGTH
	LD	(S11_TCP_BUILD_DESC+TCPB_BUFFER),HL
	LD	HL,TCPX_TX_CAPACITY-14-IPV4_HEADER_LENGTH
	LD	(S11_TCP_BUILD_DESC+TCPB_CAPACITY),HL
	LD	HL,NET_LOCAL_IP
	LD	(S11_TCP_BUILD_DESC+TCPB_SOURCE_IP),HL
	PUSH	IX
	POP	HL
	INC	HL
	LD	(S11_TCP_BUILD_DESC+TCPB_DESTINATION_IP),HL
	LD	L,(IX+CTX_LOCAL_PORT)
	LD	H,(IX+CTX_LOCAL_PORT+1)
	LD	(S11_TCP_BUILD_DESC+TCPB_SOURCE_PORT),HL
	LD	L,(IX+CTX_REMOTE_PORT)
	LD	H,(IX+CTX_REMOTE_PORT+1)
	LD	(S11_TCP_BUILD_DESC+TCPB_DESTINATION_PORT),HL
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	LD	A,(S11_SEQUENCE_OVERRIDE)
	OR	A
	JP	NZ,.USE_OVERRIDE
	LD	A,(S11_BUILD_FLAGS)
	AND	TCP_FLAG_SYN|TCP_FLAG_FIN
	JP	NZ,.USE_UNA
	LD	DE,(S11_SEGMENT_LENGTH)
	LD	A,D
	OR	E
	JP	Z,.SEQUENCE_READY
.USE_UNA
	LD	DE,CTX_SND_UNA-CTX_SND_NXT
	ADD	HL,DE
	JP	.SEQUENCE_READY
.USE_OVERRIDE
	IFDEF	TCPX_SEND_BURST
	CP	SEQUENCE_FROM_BURST
	LD	HL,S11_BURST_SEQ
	JP	Z,.SEQUENCE_READY
	ENDIF
	LD	HL,S11_TARGET_ACK
.SEQUENCE_READY
	LD	(S11_TCP_BUILD_DESC+TCPB_SEQUENCE),HL
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	LD	(S11_TCP_BUILD_DESC+TCPB_ACKNOWLEDGEMENT),HL
	LD	HL,(S11_SEGMENT_LENGTH)
	LD	(S11_TCP_BUILD_DESC+TCPB_PAYLOAD_LENGTH),HL
	LD	A,(S11_BUILD_FLAGS)
	LD	(S11_TCP_BUILD_DESC+TCPB_FLAGS),A
	IFDEF	STAGE12_LAYOUT
	; Advertise the room actually left in the pending region rather than the
	; full-or-nothing value this used to send. Announcing zero the moment a
	; single segment is queued makes every ACK for accepted data close the
	; window, so the peer stops after one MSS and the transfer degenerates
	; into stop-and-wait plus a second round trip for the reopening update.
	; Free space is capacity minus the unread bytes and minus the head the
	; reader has already consumed; RECV slides the tail down, so this stays
	; contiguous and a segment that fits the number really does fit.
	;
	; Below one MSS the answer is still zero: a dribbling window is silly
	; window syndrome, and a peer that fills it sends runts. The latch is
	; what tells RECV such a genuine close has to be reopened explicitly.
	; Advertise the room actually left after the unread tail, which is the
	; same number the accept path in PROCESS_TCP tests a segment against. So
	; every byte promised here is one that will really be taken.
	;
	; This replaces a full-or-nothing value that announced zero the moment a
	; single segment was queued. That made every ACK for accepted data close
	; the window, so the peer stopped after one MSS and the transfer became
	; stop-and-wait -- plus a second round trip for the reopening update, and
	; a peer persist-timer backoff whenever that best-effort update was lost.
	;
	; The region is linear, so the head a partial drain leaves behind is not
	; offered again until the whole region empties. That is deliberate: it
	; costs one window update per filled region rather than one per segment,
	; and it keeps the promise exact without moving bytes around. Under one
	; MSS the answer is zero -- a dribbling window is silly window syndrome --
	; and the latch is what tells RECV such a close needs an explicit reopen.
	IFDEF TCPX_SPLIT_PENDING
	CALL	PENDING_FREE
	ELSE
	LD	HL,S11_PENDING_CAPACITY
	LD	E,(IX+CTX_PENDING_OFF)
	LD	D,(IX+CTX_PENDING_OFF+1)
	OR	A
	SBC	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	SBC	HL,DE			; HL = free = CAPACITY - OFF - LEN
	ENDIF
	LD	DE,TCP_MSS
	OR	A
	SBC	HL,DE
	JP	C,.WINDOW_SHUT
	ADD	HL,DE			; restore the count the compare consumed
	IFDEF TCPX_WIDE_DIRECT_WINDOW
	; DLDIRECT is a continuous single-channel drain. Keep its receive right
	; edge at the FIFO-qualified value across public RECV boundaries; changing
	; it back to five MSS after every buffer caused the live responder to
	; alternate large bursts with one/two-frame scheduling ticks.
	; A genuinely full pending area still took .WINDOW_SHUT above.
	LD	HL,(TCP_DIRECT_WINDOW_VAR)
	ENDIF
	RES	0,(IX+CTX_WINDOW_CLOSED)
	JP	.WINDOW_READY
.WINDOW_SHUT
	LD	HL,0
	SET	0,(IX+CTX_WINDOW_CLOSED)
	ELSE
	LD	HL,TCP_RECV_WINDOW
	LD	A,(IX+CTX_PENDING_LEN)
	OR	(IX+CTX_PENDING_LEN+1)
	JP	Z,.WINDOW_READY
	LD	HL,0
	ENDIF
.WINDOW_READY
	LD	(S11_TCP_BUILD_DESC+TCPB_WINDOW),HL
	LD	HL,0
	LD	A,(S11_BUILD_FLAGS)
	AND	TCP_FLAG_SYN
	JP	Z,.MSS_READY
	LD	HL,TCP_MSS
.MSS_READY
	LD	(S11_TCP_BUILD_DESC+TCPB_MSS),HL
	LD	HL,S11_TCP_BUILD_DESC
	CALL	@TCP.BUILD
	RET	C
	LD	(S11_TCP_LENGTH),BC
	LD	(S11_IPV4_BUILD_DESC+IP4B_DATA_LENGTH),BC
	LD	HL,TCPX_TX_BUFFER+14
	LD	(S11_IPV4_BUILD_DESC+IP4B_BUFFER),HL
	LD	HL,TCPX_TX_CAPACITY-14
	LD	(S11_IPV4_BUILD_DESC+IP4B_CAPACITY),HL
	LD	HL,NET_LOCAL_IP
	LD	(S11_IPV4_BUILD_DESC+IP4B_SOURCE),HL
	PUSH	IX
	POP	HL
	INC	HL
	LD	(S11_IPV4_BUILD_DESC+IP4B_DESTINATION),HL
	LD	HL,(S11_IP_ID)
	LD	(S11_IPV4_BUILD_DESC+IP4B_IDENTIFIER),HL
	INC	HL
	LD	(S11_IP_ID),HL
	LD	A,64
	LD	(S11_IPV4_BUILD_DESC+IP4B_TTL),A
	LD	A,TCP_PROTOCOL
	LD	(S11_IPV4_BUILD_DESC+IP4B_PROTOCOL),A
	LD	HL,S11_IPV4_BUILD_DESC
	CALL	@IPV4.BUILD
	RET	C
	LD	(S11_FRAME_LENGTH),BC
	PUSH	IX
	POP	HL
	LD	DE,CTX_REMOTE_MAC
	ADD	HL,DE
	LD	DE,TCPX_TX_BUFFER
	LD	BC,6
	LDIR
	LD	HL,NETDRV_STATION_MAC
	LD	BC,6
	LDIR
	LD	A,0x08
	LD	(DE),A
	INC	DE
	XOR	A
	LD	(DE),A
	LD	HL,(S11_FRAME_LENGTH)
	LD	DE,14
	ADD	HL,DE
	LD	B,H
	LD	C,L
	LD	HL,TCPX_TX_BUFFER
	JP	@NETDRV.SEND_FRAME
	ENDIF

; WAIT_FOR_EVENT polls and dispatches all frames, including the other channel.
; In: A=event mask, BC=timeout ms. Out: A=event bits or explicit timeout.
WAIT_FOR_EVENT
	IFNDEF	UNET_DLL		; the DLL's CLOSE waits for any one answer
	PUSH	AF
	XOR	A
	LD	(S11_WAIT_ALL),A
	POP	AF
	JP	WAIT_START

; WAIT_FOR_ALL_EVENTS uses the same single deadline but waits for every masked
; event. RST remains immediately terminal and does not wait for other bits.
WAIT_FOR_ALL_EVENTS
	PUSH	AF
	LD	A,1
	LD	(S11_WAIT_ALL),A
	POP	AF
	ENDIF
WAIT_START
	LD	(S11_WAIT_MASK),A
	IFDEF	TCPX_WAIT_PROGRESS
	PUSH	AF
	LD	A,WAIT_PROGRESS_QUANTA
	LD	(S11_WAIT_PROGRESS),A
	POP	AF
	ENDIF
	CALL	@NETTIME.START
	RET	C
.WAIT_LOOP
	LD	HL,(S11_SELECTED_CONTEXT)
	PUSH	HL
	POP	IX
	CALL	CHECK_WAIT_EVENTS
	JP	C,.EVENT_READY
	IFDEF	EL3_SESSION_RX
	LD	HL,(S11_RX_DELIVERED)
	LD	A,H
	OR	L
	JR	NZ,.WAIT_NO_CANCEL	; mid-drain: DSS_SCANKEY consumes the key,
	ENDIF				; and returning data would lose the cancel
	CALL	CHECK_CANCEL
	RET	C
	IFDEF	EL3_SESSION_RX
.WAIT_NO_CANCEL
	ENDIF
	IFDEF	EL3_SESSION_RX
	; Two-phase receive. RX_BEGIN pulls only the 54-byte header prefix and
	; leaves the payload in the card's FIFO; FAST_RECEIVE then decides where
	; the rest of it should go. A plain in-order data segment for the
	; context the caller is waiting on goes straight into the pending slot
	; with its TCP checksum accumulated in the same pass (one walk over the
	; bytes instead of read-then-checksum-then-copy). Everything else is
	; pulled into STAGE9_RX_BUFFER behind the header and handled by
	; PROCESS_FRAME exactly as before.
	; RX_PENDING/READ_FRAME themselves are untouched throughout and still
	; serve every other caller (ARP, DNS/UDP, FTP).
	LD	HL,STAGE9_RX_BUFFER
	LD	BC,TCPX_RX_PREFIX
	CALL	@EL3IO.RX_BEGIN
	JP	C,.READ_ERROR
	LD	A,B
	OR	C			; EL3_OK is also 0, so "nothing queued" (CF=0,
	JP	Z,.WAIT_IDLE		; BC=0) must be told apart by BC, not A.
	LD	(S11_FRAME_LENGTH),BC
	LD	HL,STAGE9_RX_CAPACITY
	OR	A
	SBC	HL,BC
	JR	C,.SESSION_TOO_BIG	; capacity < length: the rest would not fit
					; behind the header; nothing is discarded
					; yet -- match READ_FRAME's own
					; EL3_ERR_FRAME_SIZE contract exactly.
	CALL	FAST_RECEIVE
	JR	NC,.SESSION_SLOW
	OR	A
	JP	NZ,.READ_ERROR
	JP	.SESSION_FAST
.SESSION_TOO_BIG
	CALL	@EL3IO.RX_DROP
	JP	C,.READ_ERROR
	JP	.WAIT_TICK
.SESSION_SLOW
	LD	HL,(S11_FRAME_LENGTH)
	LD	BC,TCPX_RX_PREFIX
	OR	A
	SBC	HL,BC			; always >0: a frame is at least 60 bytes
	LD	B,H
	LD	C,L
	LD	DE,STAGE9_RX_BUFFER+TCPX_RX_PREFIX
	CALL	@EL3IO.RX_PAYLOAD
	JP	C,.READ_ERROR
	ELSE
	CALL	@NETDRV.RX_PENDING
	RET	C
	OR	A
	JP	Z,.WAIT_TICK
	LD	HL,STAGE9_RX_BUFFER
	LD	BC,STAGE9_RX_CAPACITY
	CALL	@NETDRV.READ_FRAME
	JP	C,.READ_ERROR
	LD	(S11_FRAME_LENGTH),BC
	ENDIF
	CALL	PROCESS_FRAME
	RET	C
	IFDEF	EL3_SESSION_RX
.SESSION_HANDLED
	ENDIF
	IFDEF	TCPX_DIRECT_RX
	CALL	SEND_OWED_ACK
	RET	C
	ENDIF
	LD	HL,(S11_SELECTED_CONTEXT)
	PUSH	HL
	POP	IX
	CALL	CHECK_WAIT_EVENTS
	JP	C,.EVENT_READY
	IFDEF	TCPX_WAIT_PROGRESS
	JP	.WAIT_PROGRESS
	ELSE
	JP	.WAIT_TICK
	ENDIF
	IFDEF	EL3_SESSION_RX
; A segment delivered straight into the caller's buffer does not end the wait
; by itself: RECV reports S11_RX_DELIVERED, not an event, so the loop keeps
; draining while another whole MSS still fits there. That is what turns one
; RECV per segment into one RECV per bufferful -- the DSS clock read and key
; scan RECV makes are then paid once per several segments, not once per one.
; The wait ends when the buffer can no longer take a full segment, when a poll
; finds the card empty, or on any event the slow path raises (FIN, RST, a
; segment that had to go to pending).
.SESSION_FAST
	LD	A,(S11_FAST_DIRECT)
	OR	A
	JP	Z,.SESSION_HANDLED	; landed in pending: unchanged behaviour
	IFDEF TCPX_WIDE_DIRECT_WINDOW
	; Keep the selected window sliding: acknowledge each pair while several
	; frames can still be draining from the card. Waiting until the whole window
	; was consumed turned the live transfer into one burst per host-network tick.
	; Slow-path/loss traffic still requests an immediate ACK, and RECV_RETURN
	; sends any partial debt when a drain ends early.
	LD	HL,S11_ACK_OWED
	INC	(HL)
	LD	A,(HL)
	CP	TCP_ACK_EVERY
	JR	C,.SESSION_FAST_ROOM
	CALL	SEND_OWED_ACK
	RET	C
	ELSE
	LD	HL,S11_FAST_LENGTH
	INC	(HL)
	LD	A,(HL)
	CP	1
	JR	NZ,.SESSION_FAST_DEFER
	LD	A,1
	LD	(S11_ACK_OWED),A
	CALL	SEND_OWED_ACK		; first direct segment expands the initial
	RET	C			; one-MSS durable window immediately
	JR	.SESSION_FAST_ROOM
.SESSION_FAST_DEFER
	LD	HL,S11_ACK_OWED
	INC	(HL)
	LD	A,(HL)
	CP	TCP_ACK_EVERY
	JR	C,.SESSION_FAST_ROOM	; still under the threshold, stay quiet
	CALL	SEND_OWED_ACK
	RET	C
	ENDIF
.SESSION_FAST_ROOM
	LD	HL,(S11_RX_FREE)
	LD	DE,(S11_RX_DELIVERED)
	OR	A
	SBC	HL,DE
	LD	DE,TCP_MSS
	OR	A
	SBC	HL,DE
	JP	NC,.WAIT_PROGRESS	; another whole segment still fits
	XOR	A
	RET
.WAIT_IDLE
	LD	HL,(S11_RX_DELIVERED)
	LD	A,H
	OR	L
	JP	Z,.WAIT_TICK
	XOR	A
	RET
	ENDIF
.READ_ERROR
	CP	EL3_ERR_RX_ERROR
	JP	Z,.WAIT_TICK
	CP	EL3_ERR_FRAME_SIZE
	JP	Z,.WAIT_TICK
	CP	EL3_ERR_NO_FRAME
	JP	Z,.WAIT_TICK
	RET
; A poll that came back with a frame is progress, not idling, so it must not
; pay NETTIME.TICK's price: that is a 1 ms busy-wait plus a DSS_SYSTIME read
; (nettime.asm's TICK -> S7APP.WAIT_TICK and READ_WALL), and on a saturated
; transfer the loop polls once per segment. Spending it every segment cost
; more than reading the segment did. The deadline is an idle timeout, so
; skipping it while frames keep coming is right -- but the skip is bounded, so
; a peer that floods us with frames we never act on still runs the wait out.
; This applies to both receive paths: the session build reaches it from
; .SESSION_FAST_ROOM after a direct delivery, every build reaches it after a
; frame that PROCESS_FRAME handled without raising the awaited event -- which
; is what every FTP data segment does while its own RECV is the one waiting.
	IFDEF	TCPX_WAIT_PROGRESS
.WAIT_PROGRESS
	LD	HL,S11_WAIT_PROGRESS
	DEC	(HL)
	JP	NZ,.WAIT_LOOP
	LD	(HL),WAIT_PROGRESS_QUANTA
	ENDIF
.WAIT_TICK
	CALL	@NETTIME.TICK
	JP	NC,.WAIT_LOOP
	LD	A,TCP_ERR_TIMEOUT
	SCF
	RET
.EVENT_READY
	LD	C,B
	LD	A,(S11_WAIT_MASK)
	CPL
	AND	C
	LD	(IX+CTX_EVENT),A
	LD	A,(S11_WAIT_MASK)
	AND	C
	OR	A
	RET

	IFDEF	TCPX_DIRECT_RX
; Sends the ACK HANDLE_SEGMENT deferred instead of sending itself (see
; .ACK_CURRENT in HANDLE_SEGMENT): no driver call happens from inside
; PROCESS_FRAME's own call chain any more, only from here in .WAIT_LOOP,
; after PROCESS_FRAME has returned. S11_MATCH_CONTEXT is still the context
; that earned the ACK -- nothing else writes it in between. Kept as its own
; routine (not inlined into .WAIT_LOOP) so the CALL PROCESS_FRAME .. JP
; .WAIT_TICK span check-stage11.pl anchors on stays short.
; Out: CF set on send failure, propagated to WAIT_LOOP's caller.
SEND_OWED_ACK
	LD	A,(S11_ACK_NOW)
	IFDEF	EL3_SESSION_RX
	LD	HL,S11_ACK_OWED		; either flag is reason enough to send,
	OR	(HL)			; and settling one settles both
	LD	(HL),0
	ENDIF
	OR	A
	RET	Z
	XOR	A
	LD	(S11_ACK_NOW),A
	LD	HL,(S11_MATCH_CONTEXT)
	PUSH	HL
	POP	IX
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	JP	SEND_SEGMENT
	ENDIF

	IFDEF	EL3_SESSION_RX
; FAST_RECEIVE -- second half of the two-phase receive.
;
; RX_BEGIN has copied only the TCPX_RX_PREFIX-byte header; the payload is
; still in the card's FIFO and the frame is still queued. If this is a plain
; in-order data segment for the context the caller is waiting on, read the
; payload straight into the pending slot with the TCP checksum accumulated in
; the same pass, then commit. Anything else -- ARP, ICMP, a handshake or FIN
; or RST segment, a duplicate or out-of-order one, a segment for the other
; channel, one that will not fit -- is left exactly as RX_BEGIN left it, and
; WAIT_LOOP's slow path reads the rest into STAGE9_RX_BUFFER and runs
; PROCESS_FRAME on the whole frame the way it always has. The predicate below
; therefore only ever *reads* state: nothing is committed, and no driver call
; is made, until every one of its conditions holds.
;
; In: header at STAGE9_RX_BUFFER, (S11_FRAME_LENGTH)=whole frame length.
; Out: CF=0 -- not handled; nothing was read and the frame is still queued.
;      CF=1 with A=0 -- handled; the payload was read and the frame discarded
;      (whether or not the checksum matched: a bad one leaves the bytes past
;      the pending tail uncommitted and lets the peer retransmit).
;      CF=1 with A<>0 -- driver error, A is the EL3 status.
; Clobbers AF, BC, DE, HL, IX.
FAST_RECEIVE
	IFDEF	UNET_DLL
	LD	IY,(S11_SELECTED_CONTEXT)
	LD	IX,UNET_COLD_CTX
	LD	A,CFN_TCP_FAST_RECEIVE
	JP	@COLD.RUN
	ELSE
	LD	HL,(S11_SELECTED_CONTEXT)
	LD	A,H
	OR	L
	RET	Z			; nobody is waiting on a context
	PUSH	HL
	POP	IX
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_ESTABLISHED
	JR	Z,.FAST_STATE_OK
	CP	TCP_STATE_FIN_WAIT
	JR	Z,.FAST_STATE_OK
.SLOW
	OR	A			; CF=0: WAIT_LOOP takes the slow path
	RET
.FAST_STATE_OK
	LD	A,(STAGE9_RX_BUFFER+12)
	CP	0x08
	JR	NZ,.SLOW
	LD	A,(STAGE9_RX_BUFFER+13)
	OR	A
	JR	NZ,.SLOW		; ethertype must be 0800
	LD	A,(STAGE9_RX_BUFFER+14)
	CP	0x45
	JR	NZ,.SLOW		; IPv4, no options
	LD	A,(STAGE9_RX_BUFFER+20)
	AND	0xBF			; only DF may be set -- same rule as
	JR	NZ,.SLOW		; @IPV4.PARSE's own fragment check
	LD	A,(STAGE9_RX_BUFFER+21)
	OR	A
	JR	NZ,.SLOW
	LD	A,(STAGE9_RX_BUFFER+23)
	CP	TCP_PROTOCOL
	JR	NZ,.SLOW
	LD	DE,STAGE9_RX_BUFFER+30
	LD	HL,NET_LOCAL_IP
	CALL	CMP4
	JR	NZ,.SLOW
	LD	HL,STAGE9_RX_BUFFER+14
	LD	BC,IPV4_HEADER_LENGTH
	CALL	@ETHERNET.VERIFY_CHECKSUM
	JR	C,.SLOW
	LD	A,(STAGE9_RX_BUFFER+16)
	LD	H,A
	LD	A,(STAGE9_RX_BUFFER+17)
	LD	L,A			; HL = IP total length
	LD	DE,IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	OR	A
	SBC	HL,DE
	JR	C,.SLOW
	JR	Z,.SLOW			; no payload: a pure ACK or window probe
	LD	(S11_FAST_LENGTH),HL
	LD	DE,TCP_MSS+1
	OR	A
	SBC	HL,DE
	JR	NC,.SLOW		; oversized: .PROTOCOL handles it
	LD	HL,(S11_FAST_LENGTH)
	LD	DE,TCPX_RX_PREFIX
	ADD	HL,DE
	EX	DE,HL			; DE = 14 + IP total length
	LD	HL,(S11_FRAME_LENGTH)
	OR	A
	SBC	HL,DE
	JR	C,.SLOW			; frame shorter than the IP header claims
	LD	A,(STAGE9_RX_BUFFER+46)
	CP	0x50
	JR	NZ,.SLOW		; TCP options present
	LD	A,(STAGE9_RX_BUFFER+47)
	AND	~(TCP_FLAG_ACK|TCP_FLAG_PSH)
	JR	NZ,.SLOW		; SYN/FIN/RST/URG: slow path, unchanged
	LD	A,(STAGE9_RX_BUFFER+47)
	AND	TCP_FLAG_ACK
	JP	Z,.SLOW
	; The four-tuple has to be the selected context's. MATCH_CONTEXT reads
	; the source address and the TCP header through the parse descriptor,
	; so point those two fields at this frame first; @IPV4.PARSE rewrites
	; both on the slow path, so borrowing them here changes nothing.
	LD	HL,STAGE9_RX_BUFFER+26
	LD	(S11_IPV4_PARSE_DESC+IP4P_SOURCE),HL
	LD	HL,STAGE9_RX_BUFFER+34
	LD	(S11_IPV4_PARSE_DESC+IP4P_DATA),HL
	CALL	MATCH_CONTEXT
	JP	NZ,.SLOW
	LD	HL,STAGE9_RX_BUFFER+38
	LD	D,IXH
	LD	E,IXL			; avoid four stack-memory accesses in hot RX
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.SLOW		; duplicate or out of order
	; Where does it go? Straight into the caller's buffer while a RECV is
	; waiting with room left there, otherwise into the pending slot if it
	; fits. Neither -- slow path, which re-ACKs and lets the peer retry.
	LD	HL,(S11_RX_FREE)
	LD	A,H
	OR	L
	JR	Z,.FAST_TRY_PENDING
	LD	DE,(S11_RX_DELIVERED)
	OR	A
	SBC	HL,DE			; room left in the caller's buffer
	LD	DE,(S11_FAST_LENGTH)
	OR	A
	SBC	HL,DE
	JR	C,.FAST_TRY_PENDING
	LD	HL,(S11_RX_DEST)
	LD	DE,(S11_RX_DELIVERED)
	ADD	HL,DE
	LD	(S11_FAST_DEST),HL
	LD	A,1
	LD	(S11_FAST_DIRECT),A
	JR	.FAST_DEST_READY
.FAST_TRY_PENDING
	IFDEF TCPX_SPLIT_PENDING
	CALL	PENDING_FREE		; the two queues differ in size (FTP)
	ELSE
	LD	HL,S11_PENDING_CAPACITY
	LD	E,(IX+CTX_PENDING_OFF)
	LD	D,(IX+CTX_PENDING_OFF+1)
	OR	A
	SBC	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	SBC	HL,DE			; HL = CAPACITY - OFF - LEN
	ENDIF
	LD	DE,(S11_FAST_LENGTH)
	OR	A
	SBC	HL,DE
	JP	C,.SLOW			; would not fit; the slow path re-ACKs
	CALL	PENDING_BASE
	LD	L,(IX+CTX_PENDING_OFF)
	LD	H,(IX+CTX_PENDING_OFF+1)
	ADD	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	ADD	HL,DE			; base + off + len = append point
	LD	(S11_FAST_DEST),HL
	XOR	A
	LD	(S11_FAST_DIRECT),A
.FAST_DEST_READY
	; Accepted. Seed the checksum with the pseudo-header and the TCP header,
	; both of which start at an even offset, so the payload continues the
	; same word parity RX_COPY_SUM assumes.
	LD	DE,0
	LD	HL,STAGE9_RX_BUFFER+26
	LD	BC,8			; source and destination address
	CALL	@ETHERNET.ACCUMULATE
	LD	HL,TCP_PROTOCOL
	CALL	@TCP.ADD_ACCUMULATOR
	LD	HL,(S11_FAST_LENGTH)
	LD	BC,TCP_HEADER_LENGTH
	ADD	HL,BC
	CALL	@TCP.ADD_ACCUMULATOR
	LD	HL,STAGE9_RX_BUFFER+34
	LD	BC,TCP_HEADER_LENGTH
	CALL	@ETHERNET.ACCUMULATE
	EX	DE,HL
	LD	(@EL3IO.RXS_SUM),HL
	LD	DE,(S11_FAST_DEST)
	LD	BC,(S11_FAST_LENGTH)
	CALL	@EL3IO.RX_PAYLOAD_SUM
	RET	C			; A/CF already the driver's own status
	LD	HL,(@EL3IO.RXS_SUM)
	LD	A,H
	AND	L
	INC	A			; FFFFh means every word summed clean
	JR	Z,.FAST_COMMIT
	LD	HL,(S11_FAST_BADSUM)
	INC	HL
	LD	(S11_FAST_BADSUM),HL	; nothing committed: the bytes sit past
	XOR	A			; the pending tail and the peer will
	SCF				; retransmit over them
	RET
.FAST_COMMIT
	LD	DE,(S11_FAST_LENGTH)
	LD	A,(S11_FAST_DIRECT)
	OR	A
	JR	Z,.FAST_COMMIT_PENDING
	LD	HL,(S11_RX_DELIVERED)
	ADD	HL,DE
	LD	(S11_RX_DELIVERED),HL
	JR	.FAST_COMMIT_SEQUENCE
.FAST_COMMIT_PENDING
	LD	L,(IX+CTX_PENDING_LEN)
	LD	H,(IX+CTX_PENDING_LEN+1)
	ADD	HL,DE
	LD	(IX+CTX_PENDING_LEN),L
	LD	(IX+CTX_PENDING_LEN+1),H
.FAST_COMMIT_SEQUENCE
	PUSH	IX
	POP	HL
	LD	BC,CTX_RCV_NXT
	ADD	HL,BC
	CALL	ADD16_TO32		; DE is still the payload length
	LD	A,(S11_FAST_DIRECT)
	OR	A
	JR	NZ,.FAST_NO_EVENT	; direct delivery is reported by
	LD	A,EVENT_DATA		; S11_RX_DELIVERED instead; raising the
	CALL	SET_EVENT		; event would end the drain after one
.FAST_NO_EVENT				; segment

	; A data segment also carries the peer's acknowledgement and window;
	; taking them in here is what HANDLE_SEGMENT's .NO_ACK path does, and
	; skipping it would strand the next SEND on a stale window.
	LD	A,(STAGE9_RX_BUFFER+49)
	LD	(S11_TCP_PARSE_DESC+TCPP_WINDOW),A
	LD	A,(STAGE9_RX_BUFFER+48)
	LD	(S11_TCP_PARSE_DESC+TCPP_WINDOW+1),A
	LD	HL,STAGE9_RX_BUFFER+42
	LD	D,IXH
	LD	E,IXL
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JR	NZ,.FAST_ACK_OWED
	LD	HL,STAGE9_RX_BUFFER+42
	LD	D,IXH
	LD	E,IXL
	LD	BC,CTX_SND_UNA
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	CALL	UPDATE_REMOTE_WINDOW
	LD	A,EVENT_ACK
	CALL	SET_EVENT
.FAST_ACK_OWED
	LD	D,IXH
	LD	E,IXL
	LD	(S11_MATCH_CONTEXT),DE
	LD	A,(S11_FAST_DIRECT)
	OR	A
	JR	NZ,.FAST_OWED_COUNTED	; .SESSION_FAST counts the debt instead,
	LD	A,1			; so it can coalesce across segments
	LD	(S11_ACK_NOW),A		; WAIT_LOOP sends it once we return
.FAST_OWED_COUNTED
	XOR	A
	SCF
	RET
	ENDIF
	ENDIF

CHECK_WAIT_EVENTS
	LD	A,(IX+CTX_EVENT)
	LD	B,A
	LD	A,(S11_WAIT_MASK)
	AND	B
	JP	Z,.NOT_READY
	IFNDEF	UNET_DLL
	LD	C,A
	BIT	3,C
	JP	NZ,.READY
	LD	A,(S11_WAIT_ALL)
	OR	A
	JP	Z,.READY
	LD	A,(S11_WAIT_MASK)
	AND	~EVENT_RST
	CP	C
	JP	NZ,.NOT_READY
	ENDIF
.READY
	SCF
	RET
.NOT_READY
	OR	A
	RET

PROCESS_FRAME
	LD	HL,(S11_FRAME_LENGTH)
	LD	DE,14
	OR	A
	SBC	HL,DE
	RET	C
	LD	A,(STAGE9_RX_BUFFER+12)
	CP	0x08
	JP	NZ,.IGNORE
	LD	A,(STAGE9_RX_BUFFER+13)
	CP	0x06
	JP	Z,PROCESS_ARP
	OR	A
	JP	NZ,.IGNORE
	LD	HL,(S11_FRAME_LENGTH)
	LD	DE,14+IPV4_HEADER_LENGTH+TCP_HEADER_LENGTH
	OR	A
	SBC	HL,DE
	JP	C,.IGNORE
	LD	HL,STAGE9_RX_BUFFER+14
	LD	(S11_IPV4_PARSE_DESC+IP4P_BUFFER),HL
	LD	HL,(S11_FRAME_LENGTH)
	LD	DE,14
	OR	A
	SBC	HL,DE
	LD	(S11_IPV4_PARSE_DESC+IP4P_LENGTH),HL
	LD	HL,0
	LD	(S11_IPV4_PARSE_DESC+IP4P_EXPECT_SOURCE),HL
	LD	HL,NET_LOCAL_IP
	LD	(S11_IPV4_PARSE_DESC+IP4P_EXPECT_DESTINATION),HL
	LD	A,TCP_PROTOCOL
	LD	(S11_IPV4_PARSE_DESC+IP4P_EXPECT_PROTOCOL),A
	LD	HL,S11_IPV4_PARSE_DESC
	CALL	@IPV4.PARSE
	JP	C,.IGNORE
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_DATA_LENGTH)
	LD	DE,TCP_HEADER_LENGTH
	OR	A
	SBC	HL,DE
	JP	C,.IGNORE
	LD	IX,S11_CONTEXT0
	CALL	MATCH_CONTEXT
	JP	Z,.MATCHED
	IFDEF	TCPX_SINGLE_CONTEXT
		IFDEF	TCPX_LISTEN
	JP	.TRY_LISTEN
		ELSE
	JP	.IGNORE
		ENDIF
	ELSE
	LD	IX,S11_CONTEXT1
	CALL	MATCH_CONTEXT
		IFDEF	TCPX_LISTEN
	JP	Z,.MATCHED
	JP	.TRY_LISTEN
		ELSE
	JP	NZ,.IGNORE
		ENDIF
	ENDIF
	IFDEF	TCPX_LISTEN
; No established peer matched. A context bound by TCPX.LISTEN has no peer
; tuple of its own yet (CTX_REMOTE_IP/PORT are still zero, MATCH_CONTEXT
; excludes it on purpose), so it is found by state instead and fed through
; the SAME fill-and-parse below: CTX_REMOTE_PORT=0 there is exactly the
; "accept any source port" wildcard @TCP.PARSE already supports, and
; CTX_LOCAL_PORT is the bound port, so this needs no descriptor changes.
.TRY_LISTEN
	LD	IX,S11_CONTEXT0
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_LISTEN
	JP	Z,.MATCHED
		IFNDEF	TCPX_SINGLE_CONTEXT
	LD	IX,S11_CONTEXT1
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_LISTEN
	JP	Z,.MATCHED
		ENDIF
	JP	.IGNORE
	ENDIF
.MATCHED
	PUSH	IX
	POP	HL
	LD	(S11_MATCH_CONTEXT),HL
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_DATA)
	LD	(S11_TCP_PARSE_DESC+TCPP_BUFFER),HL
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_DATA_LENGTH)
	LD	(S11_TCP_PARSE_DESC+TCPP_LENGTH),HL
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_SOURCE)
	LD	(S11_TCP_PARSE_DESC+TCPP_SOURCE_IP),HL
	LD	HL,NET_LOCAL_IP
	LD	(S11_TCP_PARSE_DESC+TCPP_DESTINATION_IP),HL
	LD	L,(IX+CTX_REMOTE_PORT)
	LD	H,(IX+CTX_REMOTE_PORT+1)
	LD	(S11_TCP_PARSE_DESC+TCPP_EXPECT_SOURCE_PORT),HL
	LD	L,(IX+CTX_LOCAL_PORT)
	LD	H,(IX+CTX_LOCAL_PORT+1)
	LD	(S11_TCP_PARSE_DESC+TCPP_EXPECT_DEST_PORT),HL
	LD	HL,S11_PARSE_SEQUENCE
	LD	(S11_TCP_PARSE_DESC+TCPP_SEQUENCE),HL
	LD	HL,S11_PARSE_ACK
	LD	(S11_TCP_PARSE_DESC+TCPP_ACKNOWLEDGEMENT),HL
	LD	HL,S11_TCP_PARSE_DESC
	CALL	@TCP.PARSE
	JP	C,.IGNORE
	JP	HANDLE_SEGMENT
.IGNORE
	XOR	A
	RET

PROCESS_ARP
	LD	HL,STAGE9_RX_BUFFER
	LD	BC,(S11_FRAME_LENGTH)
	CALL	@ARP.PARSE
	JP	C,.ARP_IGNORE
	CP	2
	JP	NZ,.ARP_IGNORE
	LD	DE,STAGE9_TX_BUFFER
	LD	HL,STAGE9_RX_BUFFER
	CALL	@ARP.BUILD_REPLY
	LD	HL,STAGE9_TX_BUFFER
	JP	@NETDRV.SEND_FRAME
.ARP_IGNORE
	XOR	A
	RET

MATCH_CONTEXT
	LD	A,(IX+CTX_STATE)
	OR	A
	JP	Z,.NO_MATCH
	IFDEF	TCPX_LISTEN
	CP	TCP_STATE_LISTEN
	JP	Z,.NO_MATCH		; a listener has no peer tuple to match yet
	ENDIF
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_SOURCE)
	PUSH	IX
	POP	DE
	INC	DE
	CALL	CMP4
	JP	NZ,.NO_MATCH
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_DATA)
	LD	A,(IX+CTX_REMOTE_PORT+1)
	CP	(HL)
	JP	NZ,.NO_MATCH
	INC	HL
	LD	A,(IX+CTX_REMOTE_PORT)
	CP	(HL)
	JP	NZ,.NO_MATCH
	INC	HL
	LD	A,(IX+CTX_LOCAL_PORT+1)
	CP	(HL)
	JP	NZ,.NO_MATCH
	INC	HL
	LD	A,(IX+CTX_LOCAL_PORT)
	CP	(HL)
	JP	NZ,.NO_MATCH
	XOR	A
	RET
.NO_MATCH
	LD	A,1
	OR	A
	RET

HANDLE_SEGMENT
	XOR	A
	LD	(S11_SEGMENT_ACCEPTED),A
	IFDEF	TCPX_DIRECT_RX
	LD	(S11_ACK_NOW),A
	ENDIF
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	BIT	2,A
	JP	Z,.NOT_RST
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_SYN_SENT
	JP	Z,.RST_SYN_SENT
	IFDEF	TCPX_LISTEN
	CP	TCP_STATE_SYN_RECEIVED
	JP	Z,.RST_SYN_RECEIVED
	ENDIF
	LD	HL,S11_PARSE_SEQUENCE
	PUSH	IX
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.DONE
	JP	.ACCEPT_RST
.RST_SYN_SENT
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	AND	TCP_FLAG_ACK
	JP	Z,.DONE
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.DONE
.ACCEPT_RST
	LD	A,TCP_ERR_RESET
	LD	(IX+CTX_LAST_STATUS),A
	LD	(IX+CTX_STATE),TCP_STATE_CLOSED
	LD	A,EVENT_RST
	CALL	SET_EVENT
	XOR	A
	RET
	IFDEF	TCPX_LISTEN
; An RST during the half-open handshake aborts the passive attempt and
; re-arms LISTEN on the same port straight away: unet.inc's ACCEPT_POLL
; contract is "one inbound connection at a time", and a half-open peer
; that never completes must not tie up the only listener.
.RST_SYN_RECEIVED
	LD	L,(IX+CTX_LOCAL_PORT)
	LD	H,(IX+CTX_LOCAL_PORT+1)
	CALL	CLEAR_CONTEXT
	LD	(IX+CTX_LOCAL_PORT),L
	LD	(IX+CTX_LOCAL_PORT+1),H
	LD	(IX+CTX_STATE),TCP_STATE_LISTEN
	LD	A,EVENT_RST
	CALL	SET_EVENT
	XOR	A
	RET
	ENDIF
.NOT_RST
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_SYN_SENT
	JP	Z,HANDLE_SYN_ACK
	IFDEF	TCPX_LISTEN
	CP	TCP_STATE_LISTEN
	JP	Z,HANDLE_PASSIVE_SYN
	CP	TCP_STATE_SYN_RECEIVED
	JP	Z,.SYN_RECEIVED
	ENDIF
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	AND	TCP_FLAG_ACK
	JP	Z,.NO_ACK
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.NO_ACK
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_UNA
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	CALL	UPDATE_REMOTE_WINDOW
	LD	A,EVENT_ACK
	CALL	SET_EVENT
.NO_ACK
	; Use S11_SEGMENT_LENGTH, not S11_COPY_LENGTH, for this segment's payload
	; length: HANDLE_SEGMENT runs from inside WAIT_FOR_EVENT's frame dispatch,
	; which RECV calls *while S11_COPY_LENGTH already holds the caller's
	; destination capacity* for the RECV_COPY step below it on the same call
	; stack. Storing this segment's length in that same cell clobbered RECV's
	; capacity with whatever this segment's length happened to be; when a
	; caller requests less than one MSS per RECV (e.g. FTP's GET_LOOP, the
	; first app to do so against this deep window), RECV_COPY then trusted
	; the clobbered value and LDIR'd a whole segment into a smaller buffer,
	; overrunning S11_APP_BUFFER into RUNTIME_BASE (EL3_BASE et al, packed
	; flush right after it under STAGE13_LAYOUT) and corrupting the ISA base
	; the very next EL3 register access uses. S11_SEGMENT_LENGTH is safe here:
	; SEND's own use of it (CHOOSE_SEGMENT_LENGTH) never spans a call that can
	; re-enter HANDLE_SEGMENT, and SEND_SEGMENT_COMMON's overwrite of it for
	; the outgoing ACK below happens only after this segment's length is done
	; being read (the RCV_NXT advance just above .ACK_CURRENT).
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_PAYLOAD_LENGTH)
	LD	(S11_SEGMENT_LENGTH),HL
	LD	A,H
	OR	L
	JP	Z,.CHECK_FIN
	LD	DE,TCP_MSS+1
	OR	A
	SBC	HL,DE
	JP	NC,.PROTOCOL
	LD	HL,S11_PARSE_SEQUENCE
	PUSH	IX
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.ACK_CURRENT
	IFDEF	STAGE12_LAYOUT
	; Append after the unread tail (PENDING_OFF+PENDING_LEN) instead of
	; requiring the slot to start empty: a multi-segment window means the
	; next in-order segment can legitimately arrive before RECV drains the
	; previous one. Reject (re-ACK, unmodified) only if it will not fit;
	; the peer's own retransmit timer recovers a rejected segment.
	IFDEF TCPX_SPLIT_PENDING
	CALL	PENDING_FREE
	ELSE
	LD	HL,S11_PENDING_CAPACITY
	LD	E,(IX+CTX_PENDING_OFF)
	LD	D,(IX+CTX_PENDING_OFF+1)
	OR	A
	SBC	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	SBC	HL,DE			; HL = available = CAPACITY - OFF - LEN
	ENDIF
	LD	DE,(S11_SEGMENT_LENGTH)
	OR	A
	SBC	HL,DE
	JP	C,.ACK_CURRENT		; would not fit
	CALL	PENDING_BASE
	LD	L,(IX+CTX_PENDING_OFF)
	LD	H,(IX+CTX_PENDING_OFF+1)
	ADD	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	ADD	HL,DE			; HL = base + off + len = append point
	EX	DE,HL
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_PAYLOAD)
	LD	BC,(S11_SEGMENT_LENGTH)
	LDIR
	LD	HL,(S11_SEGMENT_LENGTH)
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	ADD	HL,DE
	LD	(IX+CTX_PENDING_LEN),L
	LD	(IX+CTX_PENDING_LEN+1),H
	ELSE
	LD	A,(IX+CTX_PENDING_LEN)
	OR	(IX+CTX_PENDING_LEN+1)
	JP	NZ,.ACK_CURRENT
	CALL	PENDING_BASE
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_PAYLOAD)
	LD	BC,(S11_SEGMENT_LENGTH)
	LDIR
	LD	HL,(S11_SEGMENT_LENGTH)
	LD	(IX+CTX_PENDING_LEN),L
	LD	(IX+CTX_PENDING_LEN+1),H
	XOR	A
	LD	(IX+CTX_PENDING_OFF),A
	LD	(IX+CTX_PENDING_OFF+1),A
	ENDIF
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	LD	DE,(S11_SEGMENT_LENGTH)
	CALL	ADD16_TO32
	LD	A,1
	LD	(S11_SEGMENT_ACCEPTED),A
	LD	A,EVENT_DATA
	CALL	SET_EVENT
.CHECK_FIN
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	AND	TCP_FLAG_FIN
	JP	Z,.ACK_IF_DATA
	LD	A,(S11_SEGMENT_ACCEPTED)
	OR	A
	JP	NZ,.ACCEPT_FIN
	LD	HL,S11_PARSE_SEQUENCE
	PUSH	IX
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.ACK_CURRENT
.ACCEPT_FIN
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	CALL	INC32
	LD	(IX+CTX_REMOTE_FIN),1
	LD	A,(IX+CTX_STATE)
	CP	TCP_STATE_FIN_WAIT
	JP	Z,.FIN_STATE_READY
	LD	(IX+CTX_STATE),TCP_STATE_CLOSE_WAIT
.FIN_STATE_READY
	LD	A,EVENT_FIN
	CALL	SET_EVENT
	JP	.ACK_CURRENT
.ACK_IF_DATA
	LD	A,(S11_SEGMENT_ACCEPTED)
	OR	A
	JP	Z,.DONE
.ACK_CURRENT
	IFDEF	TCPX_DIRECT_RX
	; Every accepted segment earns an ACK (still sent every time here, not
	; yet coalesced), but HANDLE_SEGMENT no longer sends it itself: an
	; earlier attempt at a drain-or-threshold delayed ACK called
	; @NETDRV.RX_PENDING from here, deep inside PROCESS_FRAME's own call
	; chain from WAIT_FOR_EVENT/READ_FRAME, and corrupted receive state on
	; long transfers (reproduced with the call present even when its
	; result was discarded) -- not yet root-caused. So no driver call is
	; made from this depth at all any more: .WAIT_LOOP sends the ACK for
	; S11_MATCH_CONTEXT (still valid -- nothing else writes it before
	; .WAIT_LOOP reads it) once PROCESS_FRAME has returned.
	LD	A,1
	LD	(S11_ACK_NOW),A
	XOR	A
	RET
	ELSE
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	JP	SEND_SEGMENT
	ENDIF
.PROTOCOL
	LD	A,NETDRV_ERR_PROTOCOL
	CALL	FAIL_CONTEXT
	RET
.DONE
	XOR	A
	RET
	IFDEF	TCPX_LISTEN
; A segment for a half-open (SYN_RECEIVED) context: a duplicate SYN means
; our own SYN|ACK was lost, so resend it unchanged; otherwise this is the
; handshake's closing ACK -- once it matches, move to ESTABLISHED, raise
; EVENT_SYN_ACK for ACCEPT_POLL, and fall into the ordinary ACK/data path
; above (.NO_ACK) so payload piggybacked on that same ACK isn't dropped.
.SYN_RECEIVED
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	BIT	1,A			; TCP_FLAG_SYN
	JP	Z,.SYN_RECEIVED_ACK
	LD	A,TCP_FLAG_SYN|TCP_FLAG_ACK
	LD	BC,0
	JP	SEND_SEGMENT
.SYN_RECEIVED_ACK
	AND	TCP_FLAG_ACK
	JP	Z,.DONE
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.DONE
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_UNA
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	CALL	UPDATE_REMOTE_WINDOW
	LD	(IX+CTX_STATE),TCP_STATE_ESTABLISHED
	LD	A,EVENT_SYN_ACK
	CALL	SET_EVENT
	JP	.NO_ACK
	ENDIF

	IFDEF	TCPX_LISTEN
; HANDLE_PASSIVE_SYN: a segment matched a LISTEN-state context (see
; PROCESS_FRAME's .TRY_LISTEN). Only a pure, dataless SYN starts a passive
; open; anything else here is noise (a stray ACK/data segment aimed at the
; bound port with no real connection yet) and is ignored. No ARP: the
; SYN's own Ethernet/IP source already says where to send the SYN|ACK.
HANDLE_PASSIVE_SYN
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	AND	TCP_FLAG_SYN|TCP_FLAG_ACK|TCP_FLAG_FIN
	CP	TCP_FLAG_SYN
	JP	NZ,.PASSIVE_DONE
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_PAYLOAD_LENGTH)
	LD	A,H
	OR	L
	JP	NZ,.PASSIVE_DONE
	LD	HL,(S11_IPV4_PARSE_DESC+IP4P_SOURCE)
	PUSH	IX
	POP	DE
	LD	BC,CTX_REMOTE_IP
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	BC,4
	LDIR
	LD	HL,STAGE9_RX_BUFFER+6
	PUSH	IX
	POP	DE
	LD	BC,CTX_REMOTE_MAC
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	LD	BC,6
	LDIR
	; CTX_REMOTE_PORT has no @TCP.PARSE output field of its own (an
	; established context's is already known going in) -- read it
	; straight from the TCP header's first two bytes (network order).
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_BUFFER)
	LD	A,(HL)
	INC	HL
	LD	E,(HL)
	LD	D,A
	LD	(IX+CTX_REMOTE_PORT),E
	LD	(IX+CTX_REMOTE_PORT+1),D
	; RCV_NXT = peer's ISN + 1 (the SYN consumes one sequence number).
	LD	HL,S11_PARSE_SEQUENCE
	PUSH	IX
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	CALL	INC32
	; Our own ISN: reuse GENERATE_TUPLE's own algorithm and its SND_UNA->
	; SND_NXT copy, since it is already proven and this saves duplicating
	; it here. It also reassigns CTX_LOCAL_PORT (an ephemeral port, for
	; the active-open case it was written for) -- wrong for a listener,
	; which must keep the port it was bound to, so that one field is
	; saved and restored around the call.
	LD	L,(IX+CTX_LOCAL_PORT)
	LD	H,(IX+CTX_LOCAL_PORT+1)
	PUSH	HL
	CALL	GENERATE_TUPLE
	POP	HL
	LD	(IX+CTX_LOCAL_PORT),L
	LD	(IX+CTX_LOCAL_PORT+1),H
	PUSH	IX
	POP	HL
	LD	DE,CTX_SND_NXT
	ADD	HL,DE
	CALL	INC32
	; Clamp the peer's advertised MSS exactly like HANDLE_SYN_ACK does for
	; the active-open side.
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_MSS)
	LD	A,H
	OR	L
	JP	Z,.PASSIVE_DEFAULT_MSS
	LD	DE,TCP_MSS+1
	OR	A
	SBC	HL,DE
	JP	NC,.PASSIVE_DEFAULT_MSS
	ADD	HL,DE
	JP	.PASSIVE_STORE_MSS
.PASSIVE_DEFAULT_MSS
	LD	HL,TCP_MSS
.PASSIVE_STORE_MSS
	LD	(IX+CTX_PEER_MSS),L
	LD	(IX+CTX_PEER_MSS+1),H
	LD	(IX+CTX_STATE),TCP_STATE_SYN_RECEIVED
	LD	A,TCP_FLAG_SYN|TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT
	RET	C
	XOR	A
	RET
.PASSIVE_DONE
	XOR	A
	RET
	ENDIF

HANDLE_SYN_ACK
	LD	A,(S11_TCP_PARSE_DESC+TCPP_FLAGS)
	AND	TCP_FLAG_SYN|TCP_FLAG_ACK
	CP	TCP_FLAG_SYN|TCP_FLAG_ACK
	JP	NZ,.SYN_IGNORE
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_PAYLOAD_LENGTH)
	LD	A,H
	OR	L
	JP	NZ,.SYN_IGNORE
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	CMP4
	JP	NZ,.SYN_IGNORE
	CALL	UPDATE_REMOTE_WINDOW
	LD	HL,S11_PARSE_ACK
	PUSH	IX
	POP	DE
	LD	BC,CTX_SND_UNA
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	LD	HL,S11_PARSE_SEQUENCE
	PUSH	IX
	POP	DE
	LD	BC,CTX_RCV_NXT
	EX	DE,HL
	ADD	HL,BC
	EX	DE,HL
	CALL	COPY4
	PUSH	IX
	POP	HL
	LD	DE,CTX_RCV_NXT
	ADD	HL,DE
	CALL	INC32
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_MSS)
	LD	A,H
	OR	L
	JP	Z,.DEFAULT_MSS
	LD	DE,TCP_MSS+1
	OR	A
	SBC	HL,DE
	JP	NC,.DEFAULT_MSS
	ADD	HL,DE			; restore the peer value after comparison
	JP	.STORE_MSS
.DEFAULT_MSS
	LD	HL,TCP_MSS
.STORE_MSS
	LD	(IX+CTX_PEER_MSS),L
	LD	(IX+CTX_PEER_MSS+1),H
	LD	(IX+CTX_STATE),TCP_STATE_ESTABLISHED
	LD	A,EVENT_SYN_ACK|EVENT_ACK
	CALL	SET_EVENT
	LD	A,TCP_FLAG_ACK
	LD	BC,0
	JP	SEND_SEGMENT
.SYN_IGNORE
	XOR	A
	RET

SET_EVENT
	OR	(IX+CTX_EVENT)
	LD	(IX+CTX_EVENT),A
	RET

UPDATE_REMOTE_WINDOW
	LD	HL,(S11_TCP_PARSE_DESC+TCPP_WINDOW)
	LD	(IX+CTX_REMOTE_WINDOW),L
	LD	(IX+CTX_REMOTE_WINDOW+1),H
	LD	A,H
	OR	L
	RET	Z
	LD	A,EVENT_WINDOW
	JP	SET_EVENT

PENDING_BASE
	PUSH	IX
	POP	HL
	LD	DE,S11_CONTEXT0
	OR	A
	SBC	HL,DE
	LD	DE,S11_PENDING0
	RET	Z
	LD	DE,S11_PENDING1
	RET

; PENDING_FREE: how many more bytes this context's durable queue can take.
;   In:  IX = context.
;   Out: HL = CAPACITY - PENDING_OFF - PENDING_LEN, carry clear.
;        A and DE are trashed.
; The region is linear and the head a partial drain leaves behind is not
; reused until the whole region empties, so OFF counts against the free
; space exactly like LEN does.
;
; TCPX_SPLIT_PENDING gives the two channels different capacities. FTP is the
; only client with two live channels, and they are not alike: the data
; channel wants every segment the window promises to have somewhere to land,
; while the control channel only ever queues the one reply line that arrives
; while the data channel is being drained. Sizing both for the data channel
; spent 1.4 KiB of the page on a queue that never holds more than a reply,
; and that page is where the disk buffer has to come from. The smaller
; capacity is not a correctness risk: this value is what SEND_SEGMENT_COMMON
; advertises and what the append below refuses to exceed, so a peer that
; somehow sent more would meet a rejected segment and its own retransmit,
; never an overrun.
	IFDEF TCPX_SPLIT_PENDING
PENDING_FREE
	IFDEF TCPX_SPLIT_PENDING
	; The two contexts are one CTX_SIZE apart, so their low address bytes
	; always differ; the ASSERT is what keeps that true if the block moves.
	ASSERT (S11_CONTEXT0 & 0xFF) != (S11_CONTEXT1 & 0xFF)
	LD	A,IXL
	CP	S11_CONTEXT0 & 0xFF
	LD	HL,S11_PENDING_CAPACITY
	JR	Z,.HAVE_CAPACITY
	LD	HL,S11_PENDING1_CAPACITY
.HAVE_CAPACITY
	ELSE
	LD	HL,S11_PENDING_CAPACITY
	ENDIF
	LD	E,(IX+CTX_PENDING_OFF)
	LD	D,(IX+CTX_PENDING_OFF+1)
	OR	A
	SBC	HL,DE
	LD	E,(IX+CTX_PENDING_LEN)
	LD	D,(IX+CTX_PENDING_LEN+1)
	SBC	HL,DE
	RET
	ENDIF

ABORT_CONTEXT
	LD	A,(IX+CTX_STATE)
	OR	A
	JP	Z,.CLEAR
	LD	A,TCP_FLAG_RST|TCP_FLAG_ACK
	LD	BC,0
	CALL	SEND_SEGMENT
.CLEAR
	JP	CLEAR_CONTEXT

FAIL_CONTEXT
	LD	(IX+CTX_LAST_STATUS),A
	LD	(IX+CTX_STATE),TCP_STATE_CLOSED
	SCF
	RET

CHECK_CANCEL
	IFDEF	TCPX_DISABLE_CANCEL
	; Interactive clients own the keyboard while their TCP operation is in
	; flight.  In particular, an Esc transmitted to a BBS must not be treated
	; as a local transport cancellation during SEND's ACK wait.
	XOR	A
	RET
	ELSE
	IFDEF	UNET_DLL
	; A library never grabs the keyboard uninvited: UNETAPI's SETOPT
	; CANCELKEYS defaults to 0, and only a consumer that set it wants Esc
	; polled here (UNETRTL gates its poll the same way). Polling
	; unconditionally cost an interactive client every key it had not yet
	; collected -- DSS_SCANKEY consumes, and a non-cancel key was simply
	; dropped -- on every RECV/SEND wait iteration: SprinTalk lost about
	; half of what was typed while connected through this DLL.
	LD	A,(UNET_CANCEL_MODE)
	OR	A
	RET	Z			; A=0, CF=0: same as .NO_CANCEL
	ENDIF
	LD	C,DSS_SCANKEY
	RST	DSS
	JP	Z,.NO_CANCEL
	LD	A,E
	CP	0x1B
	JP	Z,.CANCEL
	LD	A,B
	AND	KB_CTRL|KB_L_CTRL|KB_R_CTRL
	JP	Z,.NO_CANCEL
	LD	A,D
	CP	0xAC
	JP	Z,.CANCEL
	LD	A,E
	CP	0x03
	JP	Z,.CANCEL
.NO_CANCEL
	XOR	A
	RET
.CANCEL
	LD	A,NETDRV_ERR_CANCELLED
	SCF
	RET
	ENDIF

; Four-byte sequence helpers use network byte order.
COPY4
	LD	BC,4
	LDIR
	RET

CMP4
	LD	B,4
.CMP
	LD	A,(DE)
	CP	(HL)
	RET	NZ
	INC	DE
	INC	HL
	DJNZ	.CMP
	RET

INC32
	LD	DE,3
	ADD	HL,DE
	INC	(HL)
	RET	NZ
	DEC	HL
	INC	(HL)
	RET	NZ
	DEC	HL
	INC	(HL)
	RET	NZ
	DEC	HL
	INC	(HL)
	RET

DEC32
	LD	DE,3
	ADD	HL,DE
	DEC	(HL)
	RET	NZ
	DEC	HL
	DEC	(HL)
	RET	NZ
	DEC	HL
	DEC	(HL)
	RET	NZ
	DEC	HL
	DEC	(HL)
	RET

; HL -> network-order sequence, DE=16-bit addend.
ADD16_TO32
	PUSH	HL
	LD	BC,3
	ADD	HL,BC
	LD	A,(HL)
	ADD	A,E
	LD	(HL),A
	DEC	HL
	LD	A,(HL)
	ADC	A,D
	LD	(HL),A
	JP	NC,.ADD_DONE
	DEC	HL
	INC	(HL)
	JP	NZ,.ADD_DONE
	DEC	HL
	INC	(HL)
.ADD_DONE
	POP	HL
	RET

	ENDMODULE
	ENDIF
