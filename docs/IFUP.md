# IFUP

```text
IFUP
IFUP -r
IFUP -d
```

`IFUP` uses only the environment published by `NETCFG -i`. Static mode checks
the required address, card and link. DHCP mode always performs a fresh
DISCOVER/OFFER/REQUEST/ACK exchange, using bounded retry intervals of
4/8/16/16 seconds. An ACK commits the address, mask, gateway, up to two DNS
servers, DHCP server and lease duration as one transaction. `IFUP -r` renews
an active DHCP lease with three 5000 ms DHCPREQUEST attempts and `ciaddr`.
Missing mask/gateway/DNS options and a zero `yiaddr` inherit the current lease;
an ACK commits the complete result atomically.

A renewal NAK clears dynamic address/DNS/server/lease values. Renewal timeout,
malformed traffic, or cancellation preserves the old lease byte for byte.
`IFUP -d` sends a best-effort DHCPRELEASE using the saved lease and then clears
the dynamic values; repeating it without a lease succeeds without transmitting.
Renew/release reject static mode. There is no automatic static fallback and no
hidden `NET_STATE`: a lease is active only when `NET_IP_SRC=DHCP` and `NET_IP`,
`NET_DHCP_SRV`, and `NET_LEASE_SEC` are valid.

Every successful run republishes `NET_HW` with the card's actual slot and
base, the same self-healing `NETCFG -i` does. A pinned `HW` that no adapter
answers falls back to auto-probing both slots instead of failing, and prints
`[W] HW=<old> not usable, probed <new>` before continuing. A static run also
drops a lease left over from an earlier DHCP run, which is inert once
`NET_IP_SRC=STATIC` and is what `NETCFG -i` does too. In static mode the
republish is best effort: it only refreshes values the environment already
holds, so an environment that cannot be written leaves the previous
configuration intact and does not fail an interface that is up. A DHCP lease
is still published as one all-or-nothing transaction.

The card is polling-only. Link and packet waits always finish with an explicit
status; no ISA IRQ line is used. Esc or Ctrl-C cancels a DHCP wait with the DSS
cancelled exit code. Timeout diagnostics include the stage, elapsed interval,
selected slot/base, controller status and DHCP destination.
