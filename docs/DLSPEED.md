# DLSPEED and DLDIRECT

These diagnostic-only programs measure HTTP download throughput without disk
I/O. Both discard the response body into a 6 KiB application buffer, report
the exact body byte count, elapsed whole RTC seconds and KB/s, and ship only in
the FAT12 diagnostic IMG.

```text
DLDIRECT http://host[:port]/path
DLSPEED  http://host[:port]/path
```

`DLDIRECT.EXE` is the optimized native path: 3C509B polling driver, TCPX and
direct delivery into the application buffer. It keeps `FAST_DATAPATH`,
`TCPX_DIRECT_RX` and `EL3_SESSION_RX` enabled and represents the current upper
bound of this direct TCP receive path (not a raw Ethernet-controller limit).
It keeps a FIFO-qualified receive window across its short `RECV` boundaries.
Before any network traffic it reads the documented Window 3 Free Receive Bytes
register: at least 6,512 free bytes selects eleven MSS (the MAME model exposes
a 16 KiB RX partition), otherwise it uses eight MSS. Eight maximum-size stored
frames occupy 4,736 bytes and fit the smallest legal 5 KiB RX share of an
8 KiB 3C509B configuration; a genuinely full software pending area still
closes the window. The 6 KiB caller buffer remains a separate eleven-segment
batching boundary. Every outgoing frame retains the checked, finitely bounded
transmit-completion path. Clean in-order data is acknowledged every two
segments so the selected window slides while the peer refills it; slow-path,
loss, FIN and an early/partial return still force a cumulative ACK.

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

## Timing and response rules

The request is built before connecting. After `CONNECT`, each program waits at
most 2.5 seconds for a fresh RTC-second edge, takes the start snapshot, and
immediately sends the HTTP request. The stop snapshot is taken on the final
body byte before any cleanup. No progress is printed during the timed region.

The shared streaming parser applies the same rules to both programs regardless
of how TCP divides the headers or body:

- only a syntactically valid HTTP/1.x `2xx` response is accepted;
- `Content-Length` is matched case-insensitively, must fit in 32 bits, and ends the measurement at
  exactly the declared number of body bytes, even if the server keeps the
  connection open;
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

For the DLL trace, also record that at most five MSSes (2680 bytes) are in
flight, the first direct segment opens the initial one-MSS window, subsequent
ACKs normally cover two segments, and the final ACK before `RECV` returns
advertises only the durable 536-byte pending capacity. A zero window on every
MSS or one public `RECV` per data segment is a failed optimization, even if
the byte count is correct.

Repeat the same two-image comparison on the real Sprinter after read-only
discovery. Record card, slot, base, MAC, rates, console logs and pcap; do not
infer hardware acceptance from the MAME medians.

Exit classes are 0 success, 1 arguments, 2 hardware/DLL/RTC, 3 network or
timeout, 4 configuration, 6 HTTP/server error or too-short sample, and 7
cancellation.
