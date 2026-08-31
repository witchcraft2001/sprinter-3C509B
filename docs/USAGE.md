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

The IMG also contains `ARP.EXE` for bounded developer diagnostics. See
`NETCFG.TXT`, `IFUP.TXT`, and `ARP.TXT` for details.
