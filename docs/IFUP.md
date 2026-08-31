# IFUP

```text
IFUP
```

`IFUP` uses only the environment published by `NETCFG -i`. Static mode checks
the required address, card and link. DHCP mode always performs a fresh
DISCOVER/OFFER/REQUEST/ACK exchange, using bounded retry intervals of
4/8/16/16 seconds. An ACK commits the address, mask, gateway, up to two DNS
servers, DHCP server and lease duration as one transaction.

A NAK or timeout leaves all dynamic address/DNS/lease values empty and returns
a non-zero DSS code. There is no automatic static fallback. Renewal, RELEASE,
`IFUP -r`, `IFUP -d`, and persistent lease state are intentionally not part of
Stage 7.

The card is polling-only. Link and packet waits always finish with an explicit
status; no ISA IRQ line is used. Esc or Ctrl-C cancels a DHCP wait with the DSS
cancelled exit code. Timeout diagnostics include the stage, elapsed interval,
selected slot/base, controller status and DHCP destination.
