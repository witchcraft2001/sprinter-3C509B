# EL3REG.EXE

`EL3REG` is the register-layer diagnostic for the 3C509B. It safely discovers
and activates the card once, then runs the requested number of
`INIT -> SNAPSHOT -> DONE` cycles. The EEPROM is only read, and no IRQ is
used. It is included only in the developer floppy image.

## Usage

```text
EL3REG [-v] [-s 0|1] [-p #100..#1F0] [-b AUTO|#200..#3E0] [-n 1..100]
EL3REG /?
```

| Option | Meaning                                                      |
|--------|--------------------------------------------------------------|
| `-s`   | Physical ISA slot, `0` or `1`. Default `1`.                  |
| `-p`   | ISA ID port, `#100..#1F0`. Default `#110`.                   |
| `-b`   | I/O base, `AUTO` or `#200..#3E0`. Default `AUTO`.            |
| `-n`   | Cycles, `1..100`. Default `1`.                               |
| `-v`   | Verbose output.                                              |

`-n 100` checks repeated initialisation without repeating EEPROM activation.

## Behaviour

The `CYCLES21` profile uses a finite software quantum of no less than 21023
T-states. One `waitq` takes at least 1 ms at 21 MHz and about 6 ms at 3.5 MHz,
so a 100-quantum timeout is physically somewhere in the 100..601 ms range.
It is not an exact millisecond measurement.

Threshold commands send the requested value `#07FF`, but Window 5 reflects
thresholds with DWORD granularity as `#07FC`. That is a normal readback, not
an initialisation error.

Successful output contains the lines `[E0]` through `[E5]`, a 60-byte v1
snapshot, `CYCLES OK=N`, and `RESULT OK`.

## Examples

```text
EL3REG
EL3REG -v
EL3REG -n 100
EL3REG -s 0 -b #0300 -n 10
```

## Exit codes

A failure ends with `RESULT FAIL code=N`. Beyond the discovery codes shared
with `EL3INFO`, the register layer adds:

| Code | Meaning                                          |
|------|--------------------------------------------------|
| 9    | Command-In-Progress not cleared within 100 waitq |
| 10   | INIT readback did not match the expected state   |
| 11   | Invalid window number                            |

On `code=10` the `[EV] VERIFY` line shows the field number, the actual value
and the expected one. The fields are `01` MAC, `02` Media Status, `03` RX
Filter, `04` Interrupt Mask, `05` Read Zero Mask, `06` RX Early, `07` TX
Available, `08` TX Start, and `09` selected window.
