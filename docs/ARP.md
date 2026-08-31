# ARP diagnostic

```text
ARP [-v] target
```

`ARP` is a developer diagnostic included only in the IMG. It requires a static
configuration. A same-subnet address is resolved directly; an off-subnet
address is resolved through `NET_GW`. Limited and subnet broadcasts immediately
return `FF:FF:FF:FF:FF:FF`. Other addresses use three attempts of 2000 ms.

The private four-entry cache expires entries after 60 seconds and evicts the
oldest entry. Incoming requests for the local IP are answered while waiting.
Malformed and unrelated frames are consumed safely. Every execution ends with
`RESULT OK` or `RESULT FAIL code=N`. Esc or Ctrl-C cancels a wait. Timeout
diagnostics include elapsed time, selected slot/base, controller status and the
resolved next-hop target.
