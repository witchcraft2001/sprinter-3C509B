# Network kit quick reference

Copy `NETSMPL.CFG` to `NET.CFG`, edit it, then run:

```text
NETCFG -i -v
IFUP
```

`NETCFG` without arguments displays the current environment. `NETCFG -c`
checks syntax without publishing; `NETCFG -d` removes it. DHCP acquisition is
performed by each plain `IFUP` run. `IFUP -r` renews the active lease and
`IFUP -d` sends best-effort RELEASE and clears it. To switch to static addressing, edit `NET.CFG`,
run `NETCFG -i`, then run `IFUP` again.

Resolve a name or set the clock after `IFUP`:

```text
NSLOOKUP name [dns-server]
NTP [server]
```

`NTP` without a server uses `NET_NTP` and the quarter-hour `NET_TZ` offset.

Ping an IPv4 address or hostname after `IFUP`:

```text
PING [-t] [-n count] [-l size] [-i ttl] [-w milliseconds] target
```

Defaults are `-n 4 -l 32 -i 64 -w 1000`. See `PING.TXT` for ranges, exit
codes and timeout behavior. The IMG also contains `ARP.EXE` and `PINGALT.EXE`
for bounded developer diagnostics; they are not included in the user ZIP.

Test a UDP echo service from the developer IMG:

```text
UDPTEST [-n count] [-l size] [-w milliseconds] target port
```

Defaults are `1`, `16`, and `5000`; the maximum payload is 1472 bytes. See
`UDPTEST.TXT` for exact ranges and reply matching.

Test two simultaneous TCP echo channels from the developer IMG:

```text
TCPTEST [-n count] [-l 0..4096] [-w milliseconds] IPv4 port
```

Defaults are `1`, `2048`, and `5000`. The native MSS is 536 bytes; larger
buffers are divided into MSS-sized segments transparently. See `TCPTEST.TXT`.

Transfer a file in TFTP octet mode:

```text
TFTP host[:port] GET remote [-o local] [-y|-f]
TFTP host[:port] PUT local [-o remote]
```

The default request port is 69. `host` may be IPv4 or a hostname. GET prompts
before overwriting an existing file unless `-y` or `-f` is present.
