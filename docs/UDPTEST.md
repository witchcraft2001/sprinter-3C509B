# UDPTEST

`UDPTEST.EXE` is an IMG-only polling UDP echo/generator diagnostic. Run
`NETCFG -i` and `IFUP` first.

```text
UDPTEST [-n count] [-l size] [-w milliseconds] target port
```

`target` is a dotted IPv4 address or ASCII hostname. A literal bypasses DNS;
names use the common bounded resolver. Defaults are one datagram, 16 payload
bytes, and a 5000 ms timeout. Ranges are
`count=1..65535`, `size=0..1472`, `milliseconds=1..65535`, and
`port=1..65535`. Flags accept `-` or `/` and are case-insensitive.

Each datagram uses a distinct local port and a byte-index payload salted by
the datagram number. A reply must match both IP endpoints, both ports, exact
length, checksum and payload. There are at most three transmissions per
datagram, and success requires every requested reply.

Malformed, foreign, stale and bad-checksum frames are consumed once and do not
extend the deadline. The wait loop also answers valid ARP requests and ICMP
Echo Requests to the configured local address. A matching ICMP Destination
Unreachable returns DSS exit 6; timeout is exit 3, and Esc or Ctrl-C is exit 7.
Every path ends with `RESULT OK` or `RESULT FAIL code=N`.

The reusable `UDP.BUILD`/`UDP.PARSE` descriptor ABI is caller-buffer based.
`UDP.BUILD` receives source/destination IP and ports, explicit capacity and a
payload already after the eight-byte header. `UDP.PARSE` requires an exact UDP
length and fills the payload pointer/length and source/destination ports. Both
routines preserve IX/IY and reject overflow or any region crossing `#C000`.
