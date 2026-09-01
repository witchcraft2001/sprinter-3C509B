# Network kit quick reference

Copy `NETSMPL.CFG` to `NET.CFG`, edit it, then run:

```text
NETCFG -i -v
IFUP
```

`NETCFG` without arguments displays the current environment. `NETCFG -c`
checks syntax without publishing; `NETCFG -d` removes it. DHCP acquisition is
performed by each `IFUP` run. To switch to static addressing, edit `NET.CFG`,
run `NETCFG -i`, then run `IFUP` again.

Ping a dotted IPv4 address after `IFUP`:

```text
PING [-t] [-n count] [-l size] [-i ttl] [-w milliseconds] target
```

Defaults are `-n 4 -l 32 -i 64 -w 1000`. See `PING.TXT` for ranges, exit
codes and timeout behavior. The IMG also contains `ARP.EXE` and `PINGALT.EXE`
for bounded developer diagnostics; they are not included in the user ZIP.
