# UNET509B.DLL -- universal network API for the 3C509B

`UNET509B.DLL` is a loadable library (libman 1.3 / L1) that gives any
Sprinter DSS program TCP, UDP, DNS and ping through a small numbered
API, without linking the network stack into the program itself.

The same API is implemented by `UNETRTL.DLL` (RTL8019AS) and
`UNETESP.DLL` (ESP Wi-Fi) in the sibling kits. Function numbers,
register conventions and error codes are identical, so **one consumer
binary can drive any of the three cards** -- pick the DLL by name at
run time, for example from the `NET` environment variable (`509B`,
`RTL` or `WIFI`).

The authoritative contract is `src/include/unet.inc` in this source
tree. Executable declarations are checked against the sibling ABI;
comments provide common guidance (Stage 7's own gate). This page covers
what is specific to the 3C509B backend.

For running `UNETTEST.EXE` scenarios against this DLL in MAME or on
real hardware, see `docs/STAGE14_TESTING_RU.md`.

## Prerequisites

The network must already be configured, exactly as for the
stand-alone utilities:

```
NETCFG -i          seed NET_* from NET.CFG (static or DHCP)
IFUP               bring the link up
```

Both publish `NET=509B` alongside `NET_IP` and `NET_MAC`.

## Loading

`UNETTEST.EXE` (and any other consumer) loads the DLL by name through
`libman13.asm`, either from the calling program's own directory or
from a path given with `-d`. The file must keep its name
`UNET509B.DLL` so `NET=509B`-driven launchers can find it by
convention.

### Window rules

`INIT` refuses to load into window 3: that window is the ISA
aperture, and a DLL living there would page itself out on every card
access. Load it into window 1 or window 2 instead (libman's normal
choice); the loader detects and rejects window 3 itself, so a
misconfigured launcher fails cleanly at `INIT` instead of hanging the
first time a UNET function opens the ISA window.

Protocol codecs (IPv4/TCP/UDP/ICMP/ARP/DNS framing) live in a second
file appended to `UNET509B.DLL` itself, loaded into window 0 on demand
and mapped out again before the ISA window ever opens. If that overlay
cannot be loaded (missing file, out of DSS memory, I/O error),
`NETINIT` fails with `NERR_HW` and `LASTERR` reads `st=01 nerr=01
tcp=FF` (or `tcp=<DSS error>` when the DSS page allocation itself was
refused) -- this backend does not degrade to a codec-less mode, unlike
the sibling's own resolver-only overlay. The overlay also carries the
text parsers `NETINIT` needs for `NET_HW`, `NET_IDPORT`, `NET_IP` and
`NET_MASK`, so it is loaded before the environment is read: an overlay
failure is therefore reported as `NERR_HW` even on a machine that has no
network configuration at all. `GETINFO` and `LASTERR` themselves never
depend on the overlay, so they stay usable before `NETINIT` and after a
failed one.

## What this backend supports

`GETCAPS` reports `0x023F` = `TCP | UDP | RESOLVE | PING | MULTICHAN |
ASYNCSEND | LISTEN`, ABI `0x0100` -- full parity with `UNETRTL.DLL`.

| Capability   | State | Note |
|--------------|-------|------|
| `TCP`        | yes   | channels 0 and 1; `SEND` chunks at the 536-byte MSS |
| `UDP`        | yes   | connected UDP, payload up to the standard 1472-byte MTU |
| `RESOLVE`    | yes   | software DNS through the cold overlay |
| `PING`       | yes   | software ICMP echo; `DE` returns nominal polling milliseconds; see timing caveat |
| `MULTICHAN`  | yes   | channels 0 and 1 may be open simultaneously |
| `LISTEN`     | yes   | passive TCP open; see "Passive open (LISTEN)" below |
| `ASYNCSEND`  | yes   | `SEND` can suspend with `NERR_AGAIN`; see "Non-blocking SEND" below |
| `RAWETH`     | no    | no raw-frame entry point in the current ABI |
| `RXFLOW`     | no    | the card buffers receive in its own on-card FIFO |

## Receive path

The shipped DLL keeps full IPv4/TCP validation while avoiding a mandatory
one-call-per-MSS receive loop. It first reads the fixed 54-byte
Ethernet/IPv4/TCP prefix. A plain established, in-order data segment can then
be copied directly from the FIFO into the active caller buffer while its TCP
checksum is accumulated; one `RECV` continues draining complete MSSes until
the buffer no longer has room. The advertised transient window is limited to
five MSSes (2680 bytes). The first directly delivered segment is acknowledged
immediately, later segments use cumulative ACKs in pairs, and the final ACK
sent as `RECV` returns advertises only the durable 536-byte per-channel pending
capacity.

Packets for another channel, insufficient caller space, a caller buffer in
WIN0 (hidden while the cold overlay is mapped), and all non-ordinary packets
use the original pending/slow path. SYN, FIN, RST, TCP options, pure ACKs,
duplicates, out-of-order data and invalid IPv4 headers therefore retain the
complete protocol parser. The two channels keep separate pending storage and
state. A caller stack in WIN0 remains supported: `COLD.RUN` saves its address
before remapping PAGE0 and switches to the overlay's private stack without a
PUSH/POP that would cross the mapping change. Only direct delivery to a WIN0
data buffer is disabled.

A developer-only `perf-fast` image changes only the ordinary direct data copy
to omit the TCP checksum calculation. It continues checking IPv4, tuple,
sequence, flags and header shape and continues generating every outgoing
checksum. That image lives under `build/perf-fast`, is not present in either
release artifact manifest, and is not safe for distribution.

## Differences from the RTL/ESP backends

These are the only places where a portable consumer can observe which
card it got. None of them changes the calling convention.

- **`RXPAUSE` / `RXRESUME` are no-ops** and always return `NERR_OK`,
  including before `NETINIT`. The card buffers receive in its own
  FIFO, so there is no flow-control state to get wrong.
- **`SETOPT RXTRIG` returns `NERR_NOTSUP`.** It selects a hardware FIFO
  threshold this card's driver does not expose. `SETOPT CANCELKEYS`
  and `SETOPT SENDSLICE` work normally.
- **`PING` round-trip time is real milliseconds**, from this driver's
  own measured polling quantum, not a coarse tick count.
- **`GETINFO` fields 8 (SSID) and 9 (BAUD) return an empty string** --
  they are Wi-Fi properties. Field 0 (backend name) returns `509B`;
  the hardware descriptor field returns whatever `NET_HW` published
  after the last successful probe, in `<slot>/#<base>` form.
- **`LASTERR` is a fixed-layout diagnostic line**:

  ```
  509B hw=1 st=02 nerr=04 tcp=1E el3=EA/000C
  ```

  `hw` is whether `NETINIT` completed, `st` the operation stage that
  failed (01 NETINIT, 02 CONNECT, 03 SEND, 04 RECV, 05 CLOSE), `nerr`
  the UNET status returned, `tcp` the TCP-layer failure code (`FF` or a
  DSS error code for a `st=01` overlay-load failure), and `el3` the 3C509B
  driver's own last stage/status pair. Before the first failure, each
  `LASTERR` call formats the live state. A non-zero API return freezes the
  complete line at that point; successful calls do not change it, and only
  the next failure replaces it. A caller may therefore drain a peer response
  and close the channel before logging the original `SEND` failure.
- **The ARP cache is disabled.** Every `CONNECT`/`UDPOPEN`/`RESOLVE`/
  `PING` resolves its next hop with a single fresh ARP exchange
  instead of trusting a stale cache entry -- one exchange per call,
  not per segment.

## Bounded TCP retransmission

`UNET509B.DLL` splits TCP payloads at the 536-byte MSS and sends them
stop-and-wait: each segment must receive its cumulative ACK before the
next segment is sent. A missing segment or ACK is retried with the
same sequence number, with four nominal waits of 1000, 2000, 4000 and
4000 ms. Exhaustion without a full ACK returns `NERR_SEND`; `DE` reports
the confirmed prefix. Each newly acknowledged segment starts its own retry
budget, so a long transfer with delayed ACKs has no four-second total limit.
Blocking calls (`SENDSLICE=0`) never return `NERR_AGAIN`; a responding
zero-window peer can keep them waiting until its window opens. Individual
waits remain bounded, and four consecutive unanswered probes end the wait.

UNET509B retains the channel after `NERR_SEND` or `NERR_CANCEL`:

- In the window phase, no new data is outstanding (`SND.NXT == SND.UNA`),
  so the connection remains usable and CLOSE sends an orderly FIN.
- In the data phase, the earlier segment may have reached the peer;
  `SND.NXT` can remain ahead of `SND.UNA`. CLOSE aborts with RSTs. Do not
  start another SEND on this ambiguous stream: the DLL rejects it with
  `NERR_CLOSED`, `DE=0`, without transmitting or discarding received data.
  This guard also applies after cancellation or a failed retransmission.
  A peer FIN with a partial ACK also sets the guard if bytes remain in flight.
  A late ACK received by RECV does not remove the guard; CLOSE is required.
  LASTERR distinguishes a refused new SEND (`tcp=25`) from peer EOF (`tcp=20`).

The reviewed UNETRTL also retains the allocated channel until CLOSE/NETDONE after a
final SEND error; it refuses SEND with `NERR_CLOSED`, `DE=0`, and clears
STATUS's CONN flag. The portable recovery rule is CLOSE before restarting an
application transaction. After a hardware failure, the first-transmit and
retransmit cases also differ, as follows. After `NERR_HW` on the first
attempt -- the segment never left the card -- nothing is in flight, and
`CLOSE` ends the connection with an ordinary FIN. `NERR_HW` on a
retransmission is different: the earlier attempt did go out and only its
acknowledgement is missing, so the bytes stay counted as in flight and
`CLOSE` aborts. (This differs from `UNETRTL.DLL`
0.3.10, which rewinds after a failed retransmission too and then closes
with a FIN the peer may take for an old duplicate.) Only a peer RST ends the
channel inside `SEND`: the
call returns `NERR_CLOSED`, and the channel is already free (or an accepted
LISTEN channel re-armed), with any unread bytes discarded.

After a final `NERR_SEND`, `DE` proves receipt of the confirmed prefix; it
**does not prove non-delivery of the remaining bytes**. Do not automatically
resend that tail as a new SEND. Close the channel and use the application's
recovery/idempotency rules when delivery is uncertain. `NERR_AGAIN` instead
requires resuming the original call with identical arguments.

A payload-bearing frame that arrives for the channel while `SEND`
waits is not discarded: it is queued in that channel's 536-byte
receive buffer and returned by the next `RECV`.

An orderly peer FIN before the current chunk is fully acknowledged returns
`NERR_CLOSED`, not `NERR_SEND`. `DE` includes the exact cumulative ACK prefix
of that chunk. The channel and its pending response remain connected until
`RECV` has returned every byte; the following `RECV` returns
`NERR_CLOSED`/`DE=0` and releases the channel (or re-arms an accepted LISTEN
channel). `CLOSE` is idempotent afterward. A peer RST instead releases the
channel at once, as described above. If FIN carries the full ACK, the
current `SEND` succeeds; the close is reported by `RECV` instead. This is the
same public behavior as UNETRTL 0.3.8. After a full chunk ACK plus FIN,
remaining chunks are attempted in CLOSE_WAIT. Later ACKs do not replay the
previously consumed FIN; a fully acknowledged multi-chunk SEND succeeds.

To discover that queued data without blocking, call `STATUS` on the
channel: bit 2 (`UNET_ST_RXPEND`) is set while the channel holds bytes
no `RECV` has drained yet. `RECV`'s own optional flag word (`IX`) is
**always 0** in this backend: neither `UNET_RXF_MORE` nor
`UNET_RXF_XCHAN` is reported, so poll the other channel's `STATUS`
rather than waiting for a cross-channel hint.

## Non-blocking SEND

`SETOPT UNET_OPT_SENDSLICE` takes the nominal polling budget in `DE`.
Zero selects blocking mode; 1..49 are raised to 50. A nonzero value slices
both ACK waits and waits for the peer's receive window to reopen. Each wait
uses `min(attempt remaining, call remaining)`. Events and changes of phase
or retry spend the same call budget, rather than starting another full slice.

At exhaustion `SEND` returns `NERR_AGAIN` with `DE` equal to the confirmed
prefix of the **original** call. Keep its buffer unchanged and resume with
the same channel, buffer pointer and total length. Different arguments return
`NERR_STATE`. Resuming continues the saved phase; it does not immediately
retransmit or consume an attempt. Four unanswered data attempts end with
`NERR_SEND`.

A zero-window probe carries one byte at `SND.NXT-1`, without advancing the
stream. After the first probe the intervals are 1000, 2000, 4000, then 4000 ms.
A valid ACK from the selected connection resets the unanswered-probe count,
even if its window remains zero. It neither restarts the interval nor renews
the public call's budget. Four consecutive unanswered probes end with
`NERR_SEND`. Blocking mode uses the same intervals and unanswered-probe
limit. A valid response with a closed window keeps that SEND alive.

These are polling quanta, not wall-clock guarantees: frame processing, DSS
and emulator/hardware timing add overhead. A zero-elapsed event is charged
one quantum so a flood cannot create an unbounded call. Timing measured in
MAME must not be used as a calibration factor for a real Sprinter. In the
Battleship MAME profile, nominal probe intervals 1/2/4 seconds measured about
1.43/2.89/5.77 seconds (roughly 1.44x). Timers count only quanta spent inside
SEND: time between continuation calls is excluded, so infrequent resumes
stretch the wall-clock intervals further. The stack clock was not redesigned.

While suspended, `RECV` on either channel immediately returns only already
buffered TCP data, or zero bytes if none are available. It never polls the
NIC. A receive-window update is deferred until the next SEND continuation
or ordinary RECV on that channel. Failed updates remain pending for retry;
a failed channel-0 update does not skip channel 1. Thus cancelling the owner
does not strand the other channel at a zero receive window.
The error policy differs by caller: ordinary RECV treats the update as best
effort and retains it for retry. SEND treats failure of either channel's
window ACK as a final `NERR_HW`, returning the confirmed prefix in DE and
ending the continuation. If the SEND owner has bytes in flight, this also
sets the failed-stream guard: later SEND returns `NERR_CLOSED`, `DE=0`,
`tcp=25` until CLOSE. This applies even when the failed ACK belongs to the
other channel. If no data is outstanding, that failure does not set the guard.
Closed contexts do not transmit deferred window ACKs.
EOF is deferred too: an empty receive slot with a saved peer FIN returns
`NERR_OK`, `DE=0` until SEND finishes. The context and any accepted LISTEN
connection remain intact; a later ordinary RECV reports the close.

While a SEND is suspended, `CLOSE` of its owner cancels the transaction,
sends RST at `SND.NXT` and, when bytes are outstanding, also at `SND.UNA`,
then releases the channel (or re-arms LISTEN). Both RSTs are attempted even
if the first fails. It returns `NERR_OK` when all required RSTs reached the
card, or `NERR_HW` if either failed, with LASTERR stage `st=05`.
It does not wait for a peer reply or poll the keyboard. The saved continuation
is invalid afterward. These results do not prove peer receipt of a RST.

`CLOSE` of the other channel, `NETDONE`, `CONNECT`,
`UDPOPEN`, `NETINIT`, `LISTEN`, `UNLISTEN`, `RESOLVE`, `PING` and `SETOPT`
return `NERR_BUSY`. Invalid CLOSE channels still return `NERR_PARAM` first.
To shut everything down, CLOSE the owner, then call NETDONE.
Keyboard cancellation works if CANCELKEYS was enabled beforehand.
Unloading through libman's FINI hook first aborts the suspended owner with
the same RST sequence policy, including the window phase, then closes the
other channel and releases resources. NETDONE remains busy during suspension;
the RTL 0.4.3/0.4.4 abort policies for NETDONE/FINI are not identical here.
Read-only queries remain available. FIN, RST, cancellation and hardware errors
retain their distinct statuses and receive-data semantics.
An incoming FIN during the window phase closes only the peer's sending
direction: SEND continues in CLOSE_WAIT, including when that FIN opens the
peer's receive window. A window that stays shut still uses bounded probes.

### Remaining transport limits

ACKs at `RCV.NXT` are processed even if their segment also carries data or
FIN while the receive window is zero; accepting its ACK does not require
space to buffer its payload. New payload and its trailing FIN are deferred until the advertised window
reopens, even when the pending slot has some spare capacity; the accelerated
receive path falls back to the slow parser for these ACK-bearing segments.
ACKs on acceptable out-of-order and overlapping segments remain supported.
Unacceptable non-RST segments, including empty persist probes at
`RCV.NXT-1`, receive an ACK of the current receive position/window without
advancing the stream. At zero window, ACKs whose sequence is ahead of
`RCV.NXT` remain unacceptable; the reply lets the peer retransmit its missing
data. Their ACK fields do not complete our SEND.
This is not full RFC 9293 ACK/window processing: partial ACKs and window
updates on ACKs below `SND.NXT` are still ignored, and `SND.WL1/WL2` ordering
is not implemented. These can still cause a final SEND timeout with a live
peer. See [RFC 9293 §3.10.7.4](https://www.rfc-editor.org/rfc/rfc9293.html#section-3.10.7.4).

UDP has no durable queue while SEND owns the poll loop. RECV of a UDP
channel returns no data while SEND is suspended, and SEND's receive path
drops non-TCP frames. Applications combining UDP with a long TCP SEND must
account for that loss; parity with RTL's UDP handoff remains open.
UDP SEND on the other channel is allowed during a suspended TCP SEND and
preserves its continuation. All RECV modes validate the caller's buffer range
consistently, including UDP and LISTEN, during and outside suspension.
This changes ordinary UDP RECV behaviour: buffers in WIN3
(`0xC000..0xFFFF`) or the DLL's own window now return `NERR_PARAM` before
copying. Earlier candidates copied to those addresses without this check.

The local `unet.inc` preserves numeric ABI declarations and common guidance;
backend policies here do not update the shared `unet_abi.toml` generator or
the canonical generated binding in `unet_libs_asm`. Synchronizing that common
contract is a separate cross-repository change.

Developer test:

```
python3 tools/host/stage14_responder.py tcp-stall --bind 192.168.7.44 --port 8080
UNETTEST -a 192.168.7.44 8080
```

`UNETTEST -a` SETOPTs a short `SENDSLICE`, `CONNECT`s, then `SEND`s a
~1200-byte payload against the stalling peer above; it prints how many
`NERR_AGAIN` resumes were needed before the transfer settled. See
`docs/STAGE14_TESTING_RU.md` for the MAME walkthrough.

## Closing a channel

`CLOSE` tells the peer the connection is over in a way it can actually act
on, and reports whether it managed to. This is the contract `UNETRTL.DLL`
0.3.10 introduced, and `UNET509B.DLL` follows it step for step, with the
single exception noted under "Bounded TCP retransmission".

When the send stream is fully acknowledged, `CLOSE` sends `FIN+ACK` and waits
for the peer to acknowledge it, retransmitting the FIN with the same sequence
number up to three times with a 500 ms wait each. On a healthy link the
acknowledgement arrives at once and the close costs nothing measurable; a
peer that has gone away caps the call at 1.5 s. The wait runs through the
normal receive path, so a segment for the OTHER channel arriving mid-close is
queued for that channel, not discarded -- FTP's `226 Transfer complete` on the
control connection while the data connection is closing, for example. A FIN
or RST from the peer ends the wait as an answer; its data, or an ACK that
does not yet cover the FIN, does not.

When a `SEND` ended with bytes transmitted but unacknowledged -- it was
cancelled, or it exhausted its retries -- whether the peer took those bytes is
unknowable from this side, and a FIN is wrong either way: at the low sequence
number it is an old duplicate the peer ignores, at the high one it is an
out-of-order segment that never reaches end-of-stream. Both leave the peer
waiting for the rest of a request body that is never coming, holding whatever
that request locked -- which is how a cancelled WebDAV `PUT` produces
`HTTP 423 Locked` on an immediate retry. `CLOSE` therefore **aborts** such a
connection per RFC 1122 4.2.2.13, sending `RST+ACK` at both candidate
sequence numbers (first `SND.NXT`, then `SND.UNA`), since an RFC 5961 peer
honours a reset only at exactly its `RCV.NXT`. No FIN is sent.

`CLOSE` reports what the peer can be known to have learned:

| Return | Meaning |
| --- | --- |
| `NERR_OK` | the peer acknowledged the FIN, answered it, or reset us; or both RSTs of an abort went out; or there was nothing to tell it |
| `NERR_TIMEOUT` | the FIN went out (up to three times) and was met with silence |
| `NERR_CANCEL` | the user ended the wait before any answer arrived |
| `NERR_HW` | a FIN or RST never reached the wire at all |

No RST follows an unanswered FIN. A receive-side card error during the FIN
wait -- the only way this backend's wait can end that `UNETRTL` has no
counterpart for -- is reported as `NERR_TIMEOUT`: nothing the peer said was
seen.

`NERR_CANCEL` is worth handling separately from `NERR_TIMEOUT` by a consumer
that armed `UNET_OPT_CANCELKEYS`: the Esc that cancelled a transfer may still
be in the DSS keyboard buffer when the `CLOSE` that follows runs, so the first
tick of the FIN wait consumes it and the close returns immediately. Nothing
was confirmed in that case either -- clear the key, or accept that the peer
may not have been told.

Both RST transmissions of an abort are accounted for, not just the last:
only one of the two sequence numbers is the peer's `RCV.NXT`, and which one
cannot be known here, so a reset that never left the NIC may well have been
the one that would have been honoured.

A channel that is listening (or has a handshake in progress) is closed with
nothing on the wire, and its listener is unarmed. A channel with no TCP
connection -- idle, UDP, or already closed by the peer -- returns `NERR_OK`
without transmitting.

`NETDONE` closes both channels the same way, without re-arming a listener,
and reports the channel that did not close cleanly: channel 1's status when
it is not `NERR_OK`, otherwise channel 0's. The channel is released locally
in every case -- there is no state left to retry from -- but a consumer that
must know the peer was told can see that it was not, and `LASTERR`
(`st=05`) carries the underlying TCP reason. `CLOSE` stays idempotent, and a
close against an unreachable peer costs the full 1.5 s before reporting
`NERR_TIMEOUT`. During suspended SEND, CLOSE of its owner aborts immediately;
CLOSE of the other channel and NETDONE return `NERR_BUSY`.

There is no background NIC polling after a channel is released. A peer FIN
that arrives after CLOSE has returned can therefore be retransmitted by the
peer; this backend does not retain a TIME-WAIT responder for the released
channel. This existing close-lifecycle limitation is separate from SEND's
half-close handling above.

## Passive open (LISTEN)

`LISTEN` (`A`=channel, `DE`=local TCP port 1..65535) arms one closed
channel as a single-backlog server socket; there is only ever one
listening channel across both, and `LISTEN` on a second channel while
one is already listening returns `NERR_STATE`. Progress happens
inside the normal receive/poll path: an unsolicited SYN to the armed
port gets a SYN+ACK, and once the peer's final ACK arrives the channel
is promoted to an ordinary connected channel indistinguishable from
one `CONNECT` made -- `STATUS` reports the listening bit while armed,
and once a peer is accepted, the normal established-connection bits.

A peer RST during SYN_RECEIVED abandons that handshake and re-arms LISTEN
on the exact original local port. A subsequent SYN can complete a new
connection without another LISTEN call. Forced teardown of an unaccepted
LISTEN context clears it without a cold builder call or a packet.

`UNLISTEN` (`A`=the currently listening channel) stops the server. If
no peer has been accepted yet, this simply closes the socket. If a
peer *has* been accepted, that connection is left running -- `UNLISTEN`
only detaches the "please re-arm this port" bookkeeping -- and the
consumer closes it separately with `CLOSE` when done. Symmetrically,
closing an accepted connection with `CLOSE` automatically re-arms the
same channel back to `LISTEN` on the same port, so a simple
accept-serve-close loop never needs to call `LISTEN` more than once.

Developer test:

```
python3 tools/host/stage14_responder.py listen-client --host 192.168.7.21 --port 9000
```

(run it twice -- the DSS side accepts and serves exactly two peers on
the same channel before `UNLISTEN`, to prove the CLOSE-triggered
re-arm above actually works). See `docs/STAGE14_TESTING_RU.md` for the
MAME walkthrough.

## Two channels

Channel arguments 0 and 1 have independent TCP/UDP tuples, sequence
state, timeouts, close state and pending data. Applications should
follow the normal UNET rule: service a channel whose `STATUS` shows
`UNET_ST_RXPEND` promptly, and do not issue more work on a channel
whose receive buffer is already pending. Since `RECV` reports no
cross-channel hint here, an application working both channels polls
`STATUS` on each rather than relying on `UNET_RXF_XCHAN`.

## Interrupt and window state on return

Every function returns with the ISA window **closed** and the
caller's interrupt state **restored exactly as found**: the driver
samples the caller's IFF2 before disabling interrupts to map the
card, and re-enables them only if that sample said they were on. A
consumer that keeps interrupts enabled across the call gets them back
enabled; a consumer that calls in with interrupts already disabled
does not have them force-enabled by the DLL.

Transmit setup also stays within one bounded ISA session for stale-status
drain, TX-free inspection, FIFO write and the first 256 completion polls. If
completion is still unknown, the driver closes ISA before its final 1 ms wait
and single poll. A timeout recovers TX but never retransmits the frame whose
outcome is unknown.

`UNET509B.DLL` is published in both the release archive and the
floppy image, so a consumer can take the ready-built file without
installing the assembler or libman. Its L1 header records the ABI
line in the numeric version field and the full package revision in
the 15-byte text tag, for example `UNET509B v0.1.4`.
