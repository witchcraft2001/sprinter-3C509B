# EL3LB.EXE

`EL3LB.EXE` verifies the 3C509B TX/RX FIFOs in the Ethernet controller's
internal loopback. It uses no IRQ, sends no test frame onto the cable, and
does not modify the EEPROM. It is included only in the developer floppy image.

## Usage

```text
EL3LB [-v] [-s 0|1] [-p #100..#1F0] [-b AUTO|#200..#3E0] [-n 1..100]
EL3LB /?
```

| Option | Meaning                                                      |
|--------|--------------------------------------------------------------|
| `-s`   | Physical ISA slot, `0` or `1`. Default `1`.                  |
| `-p`   | ISA ID port, `#100..#1F0`. Default `#110`.                   |
| `-b`   | I/O base, `AUTO` or the EEPROM value. Default from EEPROM.   |
| `-n`   | Repetitions of the whole set, `1..100`. Default `1`.         |
| `-v`   | Verbose output.                                              |

## Behaviour

One run covers 52 frames: a matrix of eight lengths and five patterns,
followed by queues of 2 and 10 frames. Frames inside a queue carry a
distinguishable sequence byte, so loss, duplication or reordering cannot be
masked.

After the card is found the program allocates one 16 KiB DSS page. The TX
buffer sits at `#4000..#47FF` and the RX buffer at `#4800..#4FFF`. On every
exit path loopback is switched off, the card is taken through `DONE`, and the
DSS block is released.

The `CYCLES21` timer gives one `waitq` of at least 1 ms at 21 MHz and about
6 ms at 3.5 MHz; the FIFO timeout is 1000 waitq.

## Examples

```text
EL3LB
EL3LB -v
EL3LB -n 100
```

## Exit codes

Success always ends with `RESULT OK`. A failure ends with
`RESULT FAIL code=N` and reports the stage, waitq, slot/base, the general
status, the last RX/TX status, and the required and actual length.
