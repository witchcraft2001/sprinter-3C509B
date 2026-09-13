# ARP.EXE

`ARP.EXE` is a bounded ARP resolution diagnostic. It is included only in the
developer floppy image, never in the release archive. It requires a static
configuration. Run `NETCFG -i` first.

## Usage

```text
ARP [-v] target
ARP /?
```

| Option | Meaning                                                     |
|--------|-------------------------------------------------------------|
| `-v`   | Accepted for symmetry with the other diagnostics. It is     |
|        | parsed and validated but adds no output in this build.      |

`target` is a dotted IPv4 address. Hostnames are not resolved here; use
`NSLOOKUP` first if you only have a name.

## Behaviour

A same-subnet address is resolved directly; an off-subnet address is resolved
through `NET_GW`. Limited and subnet broadcasts immediately return
`FF:FF:FF:FF:FF:FF` without transmitting. Other addresses use three attempts
of 2000 ms.

The private four-entry cache expires entries after 60 seconds and evicts the
oldest entry. Incoming requests for the local IP are answered while waiting.
Malformed and unrelated frames are consumed safely. Esc or Ctrl-C cancels a
wait. Timeout diagnostics include elapsed time, selected slot/base, controller
status and the resolved next-hop target.

## Examples

```text
ARP 192.168.7.1
ARP -v 192.168.7.44
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | The target was resolved                                    |
| 1    | Usage error                                                |
| 2    | 3C509B not detected                                        |
| 3    | No reply within the deadline                               |
| 4    | Static `NET_*` environment missing; run `NETCFG -i`        |
| 5    | Local failure                                              |
| 7    | Cancelled with Esc or Ctrl+C                               |

Every run ends with `RESULT OK` or `RESULT FAIL code=N`.
