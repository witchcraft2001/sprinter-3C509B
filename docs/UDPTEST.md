# UDPTEST.EXE

`UDPTEST.EXE` is a polling UDP echo/generator diagnostic. It is included only
in the developer floppy image, never in the release archive. Run `NETCFG -i`
and `IFUP` first.

## Usage

```text
UDPTEST [-n count] [-l size] [-w milliseconds] target port
UDPTEST /?
```

| Option | Meaning                                 | Default |
|--------|-----------------------------------------|---------|
| `-n`   | Datagrams to send, `1..65535`           | 1       |
| `-l`   | Payload bytes, `0..1472`                | 16      |
| `-w`   | Per-reply timeout in ms, `1..65535`     | 5000    |

`target` is a dotted IPv4 address or ASCII hostname; a literal bypasses DNS
while names use the common bounded resolver. `port` is `1..65535`. Flags
accept `-` or `/` and are case-insensitive.

## Behaviour

Each datagram uses a distinct local port and a byte-index payload salted by
the datagram number. A reply must match both IP endpoints, both ports, exact
length, checksum and payload. There are at most three transmissions per
datagram, and success requires every requested reply.

Malformed, foreign, stale and bad-checksum frames are consumed once and do not
extend the deadline. The wait loop also answers valid ARP requests and ICMP
Echo Requests addressed to the configured local address.

## The UDP descriptor ABI

The reusable `UDP.BUILD`/`UDP.PARSE` descriptor ABI is caller-buffer based.
`UDP.BUILD` receives source/destination IP and ports, explicit capacity and a
payload already placed after the eight-byte header. `UDP.PARSE` requires an
exact UDP length and fills the payload pointer/length and source/destination
ports. Both routines preserve IX/IY and reject overflow or any region crossing
`#C000`.

## Examples

```text
UDPTEST 192.168.7.1 7
UDPTEST -n 10 -l 1472 -w 2000 192.168.7.1 7
UDPTEST echo.lan 7
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | Every requested reply matched                              |
| 1    | Usage error                                                |
| 2    | 3C509B not detected                                        |
| 3    | Timeout                                                    |
| 4    | `NET_*` environment missing or invalid; run `NETCFG -i`    |
| 5    | Local failure                                              |
| 6    | A matching ICMP Destination Unreachable arrived            |
| 7    | Cancelled with Esc or Ctrl+C                               |

Every path ends with `RESULT OK` or `RESULT FAIL code=N`.
