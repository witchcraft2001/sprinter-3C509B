# EL3INFO

`EL3INFO` performs bounded classic-ISA discovery of one 3Com 3C509B-TPO,
reads its EEPROM without modifying it, validates the IDs, MAC and checksums,
and temporarily activates the operating register window.

```text
EL3INFO [-v] [-s 0|1] [-p #100..#1F0] [-b AUTO|#200..#3E0]
```

Defaults are slot 1, ID port `#110`, and the I/O base stored in EEPROM.
An explicit `-b` changes only the current activation; it is never written to
EEPROM. `-v` prints address/resource words and both checksum words. The IRQ
field is informational and is not used by Sprinter.

Exit code 0 means success. Stable failures are: 1 usage, 2 invalid parameter,
3 card/ID not found, 4 timer timeout, 5 EEPROM checksum, 6 base, 7 active-window
verification, and 8 ISA window state. Every run ends in `RESULT OK` or
`RESULT FAIL code=N`.

Before testing real hardware, record the physical slot, card label and chosen
ID port. Start with `EL3INFO`; do not use a blind ISA scan.
