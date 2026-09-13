# PING.EXE

`PING.EXE` sends polling-only IPv4 ICMP Echo Requests through the configured
`NETDRV` backend. Run `NETCFG -i` and `IFUP` first.

## Usage

```text
PING [-t] [-n count] [-l size] [-i ttl] [-w milliseconds] target
PING /?
```

| Option | Meaning                                    | Default |
|--------|--------------------------------------------|---------|
| `-n`   | Number of requests, `1..65535`             | 4       |
| `-l`   | Payload bytes, `0..1472`                   | 32      |
| `-i`   | TTL, `1..255`                              | 64      |
| `-w`   | Per-reply timeout in ms, `1..65535`        | 1000    |
| `-t`   | Repeat until Esc or Ctrl-C                 | off     |

`target` is a dotted IPv4 address or an ASCII hostname resolved through
`NET_DNS1`/`NET_DNS2`. Flags accept `-` or `/` and are case-insensitive.

## Behaviour

`-t` cannot be combined with `-n`. Duplicate flags and extra arguments are
rejected before the card is accessed. Requests are spaced by approximately
1000 ms. The displayed RTT is based on the fixed 21 MHz `CYCLES21` timebase
used by Sprinter.

Malformed packets, bad IPv4/ICMP checksums and unrelated replies are consumed
and ignored without restarting the deadline. A finite run succeeds if at least
one reply matches source, destination, identifier, sequence, length and
payload.

`PINGALT.EXE` is an IMG-only diagnostic that repeats the same exchange through
a separate minimal one-frame polling loop; it takes the same options.

## Examples

```text
PING 192.168.7.44
PING -n 1 echo.stage10.test
PING -n 1 -l 1472 -i 255 -w 2000 203.0.113.10
PING -t 192.168.7.1
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | At least one reply matched                                 |
| 1    | Usage error                                                |
| 2    | 3C509B not detected                                        |
| 3    | No reply within the deadline                               |
| 4    | `NET_*` environment missing or invalid; run `NETCFG -i`    |
| 5    | Local failure                                              |
| 6    | A related ICMP Destination Unreachable arrived             |
| 7    | Cancelled with Esc or Ctrl+C                               |

Every path ends with `RESULT OK` or `RESULT FAIL code=N`.
