# DLSPEED

`DLSPEED.EXE` measures HTTP download throughput over the polling-only 3C509B
backend. It is a developer/measurement tool: it ships in the diagnostic IMG
only, never in the release ZIP.

```text
DLSPEED http://host[:port]/path
DLSPEED /?
```

The URL must begin with `http://` (case-insensitive); port 80 and path `/` are
the defaults, same as WGET. The response body is discarded as it arrives —
nothing is written to disk — so the measured rate is the network path alone,
never disk I/O.

Timing starts only after the TCP connection is already established: DLSPEED
waits (up to 2.5 seconds) for the DSS real-time clock's seconds field to tick
over to a fresh value, so the measured interval starts on a whole-second edge
instead of at a random point within one. It then sends the request and times
through to the last byte of the response. No progress is printed while timed
— console output would compete with the transfer for the same CPU.

Output is exact byte count, elapsed seconds, and a rate in KB/s (or B/s for a
very small or very fast transfer). A sample under one second is reported but
not trusted as a rate — the result explicitly flags it as too short instead
of printing a number rounded from too little data. Use a file of at least a
few hundred KB for a stable measurement.

## How the response is framed

The request asks for `Connection: close`, but a server is free to ignore that
and keep the socket open, which HTTP/1.1 servers do by default. So the end of
the response is decided by its own framing, in this order:

- **`Content-Length` present.** The transfer is complete the moment that many
  body bytes have been counted. The clock stops there, DLSPEED closes the
  connection with an orderly FIN, and the result is printed without waiting
  for anything further from the server. A connection that closes *before* the
  declared length arrives is a truncated transfer and is reported as an error,
  not measured.
- **No `Content-Length`.** The body then runs until the server closes the
  connection, which is the only end-of-body marker HTTP/1.0 offers for such a
  response. This case cannot distinguish an orderly end from a dropped
  connection; prefer a server that sends a length.

The header name is matched case-insensitively and the value may be padded with
spaces or tabs. If a server sends no usable length and never closes the
connection, the transfer ends on the 15-second idle timeout with a network
error rather than hanging.

## What to expect

Against the MAME 3C509B model with the stage 13 responder, a 512 KiB download
currently reports about **128 KB/s**. Earlier builds of the same test are
useful as a sanity range: 38–42 KB/s before any receive-path work, 46 KB/s
with the unrolled FIFO and checksum loops, 56 KB/s once the driver did one
ISA-window session per receive step. A number far below the current figure
means something on the receive path fell back to the slow path — check the
responder's pcap for retransmits and for ACKs arriving one per segment rather
than one per two.

DLSPEED receives into a 6 KiB buffer and the transport delivers segments into
it directly, so one `RECV` call normally takes about eleven segments. The body
is counted, not inspected: a corrupted byte that somehow passed the TCP
checksum would not be noticed here. Use WGET with a known sha256 when the
question is integrity rather than speed.

Any HTTP server that reports a correct `Content-Length` works, including
Python's own `http.server`, so a measurement on real hardware does not depend
on the MAME stage-13 responder. For example:

```sh
python3 -m http.server 8080 --directory /path/with/a/big/file
DLSPEED http://192.168.7.44:8080/big.bin
```

DLSPEED does not follow redirects and only accepts a `2xx` response; anything
else fails with the HTTP status line printed. Exit classes: 0 success,
1 arguments (missing/malformed URL), 2 hardware (including a stalled RTC),
3 network/timeout, 4 configuration, 6 HTTP/server error or a sample too short
to trust, and 7 cancellation. There is no local file, so no local-file exit
class.
