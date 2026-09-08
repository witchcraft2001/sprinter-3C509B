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

DLSPEED does not follow redirects and only accepts a `2xx` response; anything
else fails with the HTTP status line printed. Exit classes: 0 success,
1 arguments (missing/malformed URL), 2 hardware (including a stalled RTC),
3 network/timeout, 4 configuration, 6 HTTP/server error or a sample too short
to trust, and 7 cancellation. There is no local file, so no local-file exit
class.
