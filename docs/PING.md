# PING

`PING.EXE` sends polling-only IPv4 ICMP Echo Requests through the configured
`NETDRV` backend. Run `NETCFG -i` and `IFUP` first.

```text
PING [-t] [-n count] [-l size] [-i ttl] [-w milliseconds] target
```

Flags accept `-` or `/` and are case-insensitive. `target` is a dotted IPv4
address; DNS names are not supported at this stage. Defaults are four requests,
32 payload bytes, TTL 64 and a 1000 ms timeout. Ranges are:

```text
count        1..65535
size         0..1472
ttl          1..255
milliseconds 1..65535
```

`-t` repeats until Esc or Ctrl-C and cannot be combined with `-n`. Duplicate
flags and extra arguments are rejected before the card is accessed. Requests
are spaced by approximately 1000 ms. The displayed RTT is approximate because
it is derived from a bounded calibration against the DSS clock.

Examples:

```text
PING 192.168.7.44
PING -n 1 -l 1472 -i 255 -w 2000 203.0.113.10
PING -t 192.168.7.1
```

A finite run returns success if at least one reply matches source, destination,
identifier, sequence, length and payload. If none match, the exit code is 6 for
a related ICMP Destination Unreachable or 3 for timeout. Other DSS exit codes
are 1 syntax, 2 hardware, 4 configuration, 5 local failure and 7 cancellation.
Every path ends with `RESULT OK` or `RESULT FAIL code=N`.

Malformed packets, bad IPv4/ICMP checksums and unrelated replies are consumed
and ignored without restarting the deadline. `PINGALT.EXE` is an IMG-only
diagnostic using a separate minimal one-frame polling loop.
