# EL3RX.EXE

`EL3RX.EXE` receives a bounded number of Ethernet II frames through the
physical TPO datapath of the 3C509B. It is included only in the developer
floppy image.

## Usage

```text
EL3RX [-v] [-x] [-s 0|1] [-p #100..#1F0]
      [-b AUTO|#200..#3E0] [-n 1..100] [-w 1..10000]
EL3RX /?
```

| Option | Meaning                                          | Default |
|--------|--------------------------------------------------|---------|
| `-n`   | Frames to receive, `1..100`                      | 1       |
| `-w`   | Timeout in `CYCLES21` quanta, `1..10000`         | 10000   |
| `-x`   | Add a full 16-byte-per-line hex/ASCII dump       | off     |
| `-s`   | Physical ISA slot, `0` or `1`                    | 1       |
| `-p`   | ISA ID port, `#100..#1F0`                        | `#110`  |
| `-b`   | I/O base, `AUTO` or `#200..#3E0`                 | EEPROM  |
| `-v`   | Verbose output                                   | off     |

One quantum is roughly 1..6 ms; `-w` is not an exact millisecond interface.

## Behaviour

The RX filter stays at `individual+broadcast`, so unicast traffic addressed to
another station should never reach the program. For each frame it prints the
source and destination MAC, the EtherType, the length without FCS, and a
software IEEE CRC32 over exactly those bytes. A successful read consumes the
packet with exactly one `RX_DISCARD`.

`EL3.DONE` and the release of the DSS page also run after an error.

## Examples

```text
EL3RX
EL3RX -n 10 -w 5000
EL3RX -x -v
```

## Exit codes

Success ends with `RESULT OK`. A timeout or hardware error prints
`RESULT FAIL code=N` with the detailed EL3 code. The DSS exit code follows the
shared classification in `HOWTO.TXT`; a timeout is 3.
