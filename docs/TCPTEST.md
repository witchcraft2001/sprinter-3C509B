# TCPTEST.EXE

`TCPTEST.EXE` is a polling TCP echo diagnostic that exercises two simultaneous
channels. It is included only in the developer floppy image, never in the
release archive. Run `NETCFG -i` and `IFUP` first.

## Usage

```text
TCPTEST [-n count] [-l 0..4096] [-w milliseconds] IPv4 port
TCPTEST /?
```

| Option | Meaning                                     | Default |
|--------|---------------------------------------------|---------|
| `-n`   | Cycles to run, `1..65535`                   | 1       |
| `-l`   | Bytes per channel, `0..4096`                | 2048    |
| `-w`   | Receive timeout in ms, `1..65535`           | 5000    |

`port` is `1..65535`. The target is currently a dotted IPv4 address only.

## Behaviour

Each cycle opens two simultaneous connections with distinct local ports, sends
and verifies a separate deterministic byte pattern on each channel, and closes
both connections.

The public native MSS is 536 bytes, matching the sibling interface. A `SEND`
buffer may be larger: the transport transparently divides it into segments no
larger than the effective local/peer MSS. The default 2048-byte and maximum
4096-byte checks therefore exercise several segments without changing the
visible API limit.

The transport is polling-only. SYN is attempted three times with bounded
delays; data retransmission uses 1, 2 and 4 second waits; close has one finite
5-second deadline for both FIN directions. Duplicate and out-of-order data are
acknowledged without reassembly. A full per-channel receive slot advertises a
zero window; draining it reopens the 536-byte window. A persist probe repeats
one already acknowledged octet and never consumes application data. Esc or
Ctrl-C cancels a wait.

A transient remote RST causes one complete transport reset and reconnect
attempt; permanent failure is reported normally.

## Examples

```text
TCPTEST 192.168.7.1 7
TCPTEST -n 5 -l 4096 -w 10000 192.168.7.1 7
TCPTEST -l 0 192.168.7.1 7
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | Both channels echoed their pattern in every cycle          |
| 1    | Usage error                                                |
| 2    | 3C509B not detected                                        |
| 3    | Connect/receive timeout, or a content mismatch             |
| 4    | `NET_*` environment missing or invalid; run `NETCFG -i`    |
| 5    | Local cleanup failure                                      |
| 7    | Cancelled with Esc or Ctrl+C                               |

Successful cycles print `[E1] channel=N bytes=M` for both channels and end in
`RESULT OK`. Every failure ends in `RESULT FAIL code=N`.
