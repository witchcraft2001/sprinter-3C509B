# TCPTEST

`TCPTEST.EXE` is an IMG-only polling TCP echo diagnostic. Run `NETCFG -i` and
`IFUP` first.

```text
TCPTEST [-n count] [-l 0..4096] [-w milliseconds] IPv4 port
```

Defaults are one cycle, 2048 bytes per channel and a 5000 ms receive timeout.
Ranges are `count=1..65535`, `size=0..4096`, `milliseconds=1..65535` and
`port=1..65535`. The target is currently a dotted IPv4 address.

Each cycle opens two simultaneous connections with distinct local ports, sends
and verifies a separate deterministic byte pattern on each channel, and closes
both connections. The public native MSS is 536 bytes, matching the sibling
interface. A `SEND` buffer may be larger: the transport transparently divides
it into segments no larger than the effective local/peer MSS. Thus the default
2048-byte and maximum 4096-byte checks exercise several segments without
changing the visible API limit.

The transport is polling-only. SYN is attempted three times with bounded
delays; data retransmission uses 1, 2 and 4 second waits; close has one finite
5-second deadline for both FIN directions. Duplicate and out-of-order data are
acknowledged without reassembly. A full per-channel receive slot advertises a
zero window; draining
it reopens the 536-byte window. A persist probe repeats one already acknowledged
octet and never consumes application data. Esc or Ctrl-C cancels a wait.

Successful cycles print `[E1] channel=N bytes=M` for both channels and end in
`RESULT OK`. Every failure ends in `RESULT FAIL code=N`. A transient remote RST
causes one complete transport reset and reconnect attempt; permanent failure is
reported normally. DSS exits distinguish argument, configuration, hardware,
network, cancellation and local cleanup failures.
