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

`DLSPEED.EXE` loads `UNET509B.DLL` into WIN1 through libman 1.3. It first tries
the DLL beside the executable using DSS `APPINFO`, then retries
`UNET509B.DLL` in the current directory. It requires a compatible UNET ABI
1.x and `UNET_CAP_TCP`, enables `CANCELKEYS`, and uses only the public
`NETINIT`, `CONNECT`, `SEND`, `RECV`, `CLOSE` and `NETDONE` calls. Every exit
after loading the DLL runs the applicable close, network teardown and
`l_free` cleanup.

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

Repeat the four-run block until at least five successful results have been
recorded for each executable. Reject failed, truncated or cancelled runs; do
not silently substitute their partial byte counts. Compare the median KB/s of
each set, and record the exact byte count, order, target, MAME revision or real
Sprinter/card details, console log and pcap. A valid run must report 4194304
bytes, `RESULT OK`, an orderly FIN without RST, no hang, and a second
successful run of the same executable.

No fixed speed threshold is specified: MAME and physical systems differ. The
meaningful regression signal is the median change on the same bench.

Exit classes are 0 success, 1 arguments, 2 hardware/DLL/RTC, 3 network or
timeout, 4 configuration, 6 HTTP/server error or too-short sample, and 7
cancellation.
