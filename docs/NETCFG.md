# NETCFG

`NETCFG` manages the transactional `NET_*` environment configuration. It reads
only `NET.CFG` in the executable directory, accepts LF or CRLF and whole-line
`#` comments, warns about unknown or repeated keys, and uses the last repeated
value. A malformed or oversized file, card error, or environment error leaves
the old environment intact.

```text
NETCFG
NETCFG -i [-v]
NETCFG -c [-v]
NETCFG -d
NETCFG -v
```

With no option it displays published values. `-i` validates the file and card,
then commits the environment. `-c` validates the file without using the card or
publishing; with `-v` it also validates the card. `-d` removes every variable
owned by this package. `-v` alone is the detailed file-and-card check without a
commit. Every run ends with `RESULT OK` or `RESULT FAIL code=N`.

The keys are `NET`, `HW`, `IDPORT`, `MAC`, `IP`, `NETMASK`, `GATEWAY`, `DNS1`,
`DNS2`, `NTP`, and `TZ`. `NET` must be `509B`; `HW` is `AUTO` or
`0/#base`/`1/#base`; `IDPORT` is `#100..#1F0` on a 16-byte boundary.
An empty `MAC` uses the read-only EEPROM address. `IP=DHCP` selects DHCP;
otherwise it is the static address and requires `NETMASK`.

`TZ` is empty for UTC or `[+|-]H`, `[+|-]HH`, `[+|-]H:MM`, or
`[+|-]HH:MM`. The sign defaults to positive; minutes must be exactly `00`,
`15`, `30`, or `45`, and the range is `-12:00..+14:00`. Examples include
`+5:30`, `+5:45`, `+9:30`, `+12:45`, and `-3:30`.

In DHCP mode `NETCFG -i` clears old dynamic IP, DNS, server, and lease values.
It does not contact a DHCP server; run `IFUP` next.
