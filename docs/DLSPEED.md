# DLSPEED and DLDIRECT

These diagnostic-only programs measure HTTP download throughput without disk
I/O. Both discard the response body into a 6 KiB application buffer, report
the exact body byte count, elapsed whole RTC seconds and KB/s, and ship only in
the FAT12 diagnostic IMG.

## Usage

```text
DLDIRECT http://host[:port]/path [-w 1-44]
DLSPEED  http://host[:port]/path
DLDIRECT /?
DLSPEED /?
```

Both take a single plain-HTTP URL. `DLSPEED` has no options; `DLDIRECT`'s one
option is a receive-path experiment knob, described in
[Receive-window experiments](#receive-window-experiments). Run `NETCFG -i` and
`IFUP` first.

## The two paths

`DLDIRECT.EXE` is the optimized native path: 3C509B polling driver, TCPX and
direct delivery into the application buffer. It keeps `FAST_DATAPATH`,
`TCPX_DIRECT_RX` and `EL3_SESSION_RX` enabled and represents the current upper
bound of this direct TCP receive path (not a raw Ethernet-controller limit).

It announces a whole-Ethernet-payload receive MSS of 1,460 (`TCPX_LARGE_MSS`).
This is the single largest lever on the receive rate, and it is a processing
cost rather than a wire cost: roughly 55% of the work a segment costs is
per-segment rather than per-byte (the ISA sessions, the 54-byte header read,
the fast-path predicate, and the acknowledgement's own build and transmit), so
a 1,460-byte segment amortizes that fixed part over 2.7x more payload. It costs
no image bytes, only constants and the receive page's geometry, which is why
`WGET` and `FTP` announce it too even though neither has room for the two-phase
receive. `UNET509B.DLL` stays at 536: its durable queue is one MSS-sized slot
per channel carved out of the consumer's address space, and at 1,460 that
degenerates into a zero-window stop/start cycle. The sibling RTL8019A kit draws
the line in the same place, and its direct client has run 1,460 against a
536-byte DLL throughout.

It paces a nine-MSS receive window across its short `RECV` boundaries. The
card stores only three maximum-size frames (4,548 bytes of the smallest legal
5 KiB RX share of an 8 KiB 3C509B), and a server sends its frames back to back,
so what overflows the FIFO is a burst of four, not the window size (see
[Receive-window experiments](#receive-window-experiments)). `DLDIRECT`
therefore acknowledges every in-order segment and moves the advertised right
edge (acknowledgement plus window) at most two MSS per segment it sends: the
handshake ACK offers one MSS, the request three, and every later ACK can
release at most two frames while the window grows to its target. A genuinely
full software pending area still closes the window. The Window 3 Free Receive
Bytes value is read once for the report only. The 5 KiB caller buffer remains a
separate three-segment batching boundary, and the durable software pending
region holds two whole segments. Every outgoing frame retains the checked,
finitely bounded transmit-completion path. Slow-path, loss, FIN and an
early/partial return still force a cumulative ACK.

Because the advertised MSS only matters if the peer honours it, both test peers
do: the raw MAME responder (`tools/host/stage13_responder.py`) and the
actual-EXE harness size each segment by the option on the client's own SYN, and
the Stage 13 EXE test asserts the segments actually arrive at 1,460.

`DLSPEED.EXE` loads `UNET509B.DLL` into WIN1 through libman 1.3. It first tries
the DLL beside the executable using DSS `APPINFO`, then retries
`UNET509B.DLL` in the current directory. It requires a compatible UNET ABI
1.x and `UNET_CAP_TCP`, enables `CANCELKEYS`, and uses only the public
`NETINIT`, `CONNECT`, `SEND`, `RECV`, `CLOSE` and `NETDONE` calls. Every exit
after loading the DLL runs the applicable close, network teardown and
`l_free` cleanup.

The release DLL uses the optimized two-phase receive path without weakening
validation: it reads the 54-byte Ethernet/IPv4/TCP prefix, accepts direct
delivery only for an established in-order data segment, verifies both IPv4
and TCP checksums, and streams the payload from the card FIFO into the
application's buffer in the same checksum pass. One `RECV` may drain up to
five 536-byte segments into the 6 KiB buffer. Slow-path packets, data for the
other channel, a caller buffer in WIN0, or a segment that does not fit are
kept in the channel's ordinary 536-byte pending area and receive the complete
protocol validation used before this optimization.

`make perf-fast` creates the non-release comparison image
`build/perf-fast/sprinter-3c509b-fast.img`. Its DLL differs only in the cold
receive policy: an otherwise valid, established, in-order data segment uses a
plain FIFO copy instead of calculating its TCP checksum. IPv4 checksum,
tuple/sequence/flags/header checks, SYN/FIN/RST and every slow path remain
enabled, and all transmitted TCP/IPv4 checksums are still generated. This
image is intentionally absent from the IMG/ZIP manifest and must never be
used as a release build.

The difference `DLDIRECT - DLSPEED` is intentionally the full price of the
public DLL path: libman dispatch, UNET API handling and the DLL's receive path.
There is no `DLDIRCP` midpoint in this design.

## Receive-window experiments

A real internet download is limited by the receive window, not by the Z80: a
capture of `DLDIRECT` fetching a 5.76 MB file over a 100 ms round trip showed
the server sending exactly three segments per acknowledgement cycle (35.9 KB/s),
while the Sprinter needed only about 8 ms per 1,460-byte segment. A single lost
segment also cost two retransmission timeouts, because a three-segment window
cannot produce the three duplicate ACKs fast retransmit needs and the segments
behind the hole are discarded. `DLDIRECT` therefore takes one option and
reports what the run saw, so the window can be measured on the real path:

- `-w N` sets the window target to N whole 1,460-byte segments (1-44; 44 is
  the largest window an unscaled TCP header carries) instead of twelve.

Every in-order segment is acknowledged at once. The window starts at three
segments (or at N when that is smaller) and grows by one segment each time
as many segments were sent as it holds, until it reaches the target; the
advertised right edge never moves more than two segments per ACK.

The option may precede or follow the URL. Two extra lines are printed, neither
inside the timed region:

```text
ESTABLISHED.
win 12 fifo 5119 syn 81
...
ahead 0 kept 0 dup 0 badsum 0 overruns 0
RESULT OK
```

| Field | Meaning |
|-------|---------|
| `win` | Receive window target in whole 1,460-byte segments (`-w`) |
| `fifo` | Window 3 Free Receive Bytes read once on the idle card: the RX share of the FIFO |
| `syn` | Poll ticks between the SYN and its SYN\|ACK; about 1.3 ms per tick on the real Sprinter measured against a pcap |
| `ahead` | Data segments that arrived past a hole: a segment before them was lost on the path or dropped by a full card |
| `kept` | Of those, segments stored in the out-of-order queue and delivered once the hole filled; the rest were discarded |
| `dup` | Data segments retransmitted after they were already taken |
| `badsum` | Direct-path segments whose TCP checksum failed |
| `overruns` | The card's own Window 6 RX Overruns counter (8-bit, cleared at start): frames lost because the FIFO was full |

The counter line appears on every exit after the card was configured, including
failures and Esc, so a stalled experiment still reports what it saw.

Collect results against one multi-megabyte internet URL, the same one for every
run, preferably a server at least 50 ms away:

1. Run `DLDIRECT url` without options three times. Note the three KB/s results
   and both extra lines.
2. Run `DLDIRECT url -w N` for N = 9, 12, 15 and 20, twice each.
3. For every run record the summary line, the `win`, `syn`, `ahead`, `dup` and
   `overruns` values, and whether the run ended with `RESULT OK`.
4. Capture a pcap of at least one run per window value. On a Keenetic router
   disable flow offload for the capture (`no ppe hardware`, `no ppe software`)
   and re-enable it afterwards; with offload on, server frames stop appearing
   after a few seconds.

Reading the results: a rate that keeps rising with `-w` while `overruns` stays 0
means the window is the limit and the card still keeps up. Non-zero `overruns`
means some burst still reached four frames. `ahead` counts the segments
discarded behind each such hole; `ahead` without `overruns` is loss on the
internet path.

The first matrix (2026-09-17, 5.76 MB over a 90-110 ms round trip, before
pacing) is recorded in `specs.md`: every server retransmission was a card
overrun or a segment discarded behind one, a three-MSS window gave 38 KB/s,
nine MSS 71 KB/s, twelve MSS collapsed to 22 KB/s, and nine MSS acknowledged
per segment reached 108 KB/s with a few overruns left from the server's
initial burst. Pacing is the fix for that remainder.

An evening rerun with slow growth reached 144 KB/s with no loss at all; every
hole left in the other runs was a loss before the router, and each cost about
two seconds because the segments behind it were discarded and resent one per
round trip. `DLDIRECT` therefore keeps up to eleven such segments in a DSS page
of its own (mapped over WIN3 only while one is copied), so the retransmission
that fills a hole is acknowledged together with everything kept behind it. The
window then restarts at what the previous ACK still promised, and segments
behind a hole take the single-pass checksummed read like in-order ones.
Growing that window back one MSS per window cost about 0.6 s per loss on the
real path, so while the card stays empty the receive loop reopens it itself:
one MSS and a window update every four idle polls (about 8 ms, the Z80's cost
per segment) up to the target. The peer answers each update with one frame.
The start opens the same way from the first data segment, and while a hole is
open no ACK moves the window: a moved window stops the peer counting the ACK
as a duplicate, which on the real path turned an early loss into a 2.9 s
retransmission timeout. Capping that reopening at half the target to keep the
peer paced was tried and reverted: six MSS cap the flow near 83 KB/s at a
100 ms round trip, and a hole opening under such a window leaves the peer too
few duplicate ACKs to retransmit without its own timeout, which on the real
path backed off to 7.8 s and hit the receive watchdog. While a hole is open and
nothing arrives, the idle loop instead repeats the same duplicate ACK, up to
eight times, so three of them reach the peer whatever its congestion window
holds.

The paced rerun (same day) kept the steady flow clean, 87 KB/s at nine MSS
and 137 KB/s at twelve, but still overran while the window grew one MSS per
ACK: each ACK then released a pair, twice the drain rate. Twelve MSS became
the default and the window now grows one MSS per window of segments.

## Timing and response rules

The request is built before connecting. After `CONNECT`, each program waits at
most 2.5 seconds for a fresh RTC-second edge, takes the start snapshot, and
immediately sends the HTTP request. The stop snapshot is taken on the final
body byte before any cleanup. No progress is printed during the timed region.

The shared streaming parser applies the same rules to both programs regardless
of how TCP divides the headers or body:

- only a syntactically valid HTTP/1.x `2xx` response is accepted;
- `Content-Length` is matched case-insensitively, must fit in 32 bits, and
  ends the measurement at exactly the declared number of body bytes, even if
  the server keeps the connection open;
- a response without `Content-Length` is accepted as HTTP/1.0 close-delimited
  framing and completes only when the peer closes;
- closing before a declared length is a truncated-transfer error;
- `Transfer-Encoding` (including chunked bodies) and compressed
  `Content-Encoding` are rejected rather than measured as payload;
- a blocking UNET `RECV` that returns zero bytes is the final 15-second idle
  timeout; it is never retried indefinitely;
- Esc or Ctrl+Z cancels the DLL client through `SETOPT(CANCELKEYS)`; the direct
  client accepts its existing Esc/Ctrl+C cancellation keys.

A zero-second sample is rejected as too short. Use the deterministic 4 MiB
Stage 13 payload or another multi-megabyte file so whole-second RTC rounding
does not dominate the result.

## Comparable measurement

Use one machine, card, configuration and 4 MiB URL for both programs. Warm up
the server once, then alternate in this order:

```text
DLDIRECT
DLSPEED
DLSPEED
DLDIRECT
```

Repeat the four-run block separately with the release image and the non-release
fast image until each image has at least five successful results from each
executable. Reject failed, truncated or cancelled runs; do not silently
substitute their partial byte counts. Compare medians on the same bench and
record the exact byte count, order, target, image variant, MAME revision or
real Sprinter/card details, console log and pcap. A valid run must report
4194304 bytes, `RESULT OK`, valid outgoing IPv4/TCP checksums, an orderly FIN
without RST, no hang, and a second successful run of the same executable.

The mandatory MAME gates are:

- release image: median `DLDIRECT >= 150 KB/s` and median
  `DLSPEED / DLDIRECT >= 40%`;
- fast image: median `DLDIRECT >= 180 KB/s` and median
  `DLSPEED >= 76 KB/s`.

For the `DLDIRECT` trace, record that its SYN advertises MSS 1460, that the
body segments really are 1460 bytes, that the request advertises 4,380 (three
MSS), that no advertised right edge moves more than 2,920 past the previous
one, that after a lost segment the server resends only that segment and the
next ACK jumps past everything received behind it with a window of at most
2,920 that then grows one MSS per window, that the window grows one MSS at a time (each value held for about
as many ACKs as it has segments) and stays at 17,520 (twelve MSS) on either
FIFO size, and
that cumulative ACKs normally advance by 1,460. A run that still shows
536-byte segments means the responder ignored the MSS option, not that the
client failed to ask.

For the DLL trace, also record that at most five MSSes (2680 bytes) are in
flight, the first direct segment opens the initial one-MSS window, subsequent
ACKs normally cover two segments, and the final ACK before `RECV` returns
advertises only the durable 536-byte pending capacity. A zero window on every
MSS or one public `RECV` per data segment is a failed optimization, even if
the byte count is correct.

Repeat the same two-image comparison on the real Sprinter after read-only
discovery. Record card, slot, base, MAC, rates, console logs and pcap; do not
infer hardware acceptance from the MAME medians.

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | OK                                                         |
| 1    | Usage error                                                |
| 2    | Hardware, DLL load, or RTC failure                         |
| 3    | Network or timeout error                                   |
| 4    | `NET_*` environment missing or invalid; run `NETCFG -i`    |
| 6    | HTTP/server error, or a sample too short to time           |
| 7    | Cancelled by the user                                      |

Every run ends with `RESULT OK` or `RESULT FAIL code=N`.
