# EL3TX.EXE

`EL3TX.EXE` sends a bounded series of Ethernet II frames through the physical
TPO datapath of the 3C509B. It is a bench instrument and is included only in
the developer floppy image.

## Usage

```text
EL3TX [-v] [-s 0|1] [-p #100..#1F0] [-b AUTO|#200..#3E0]
      -d MAC [-t #0600..#FFFF] [-l 14..1514]
      [-f 00|FF|55|AA|INC] [-n 1..100] [-w 1..10000]
EL3TX /?
```

| Option | Meaning                                          | Default |
|--------|--------------------------------------------------|---------|
| `-d`   | Destination MAC. Required.                       | --      |
| `-t`   | EtherType, `#0600..#FFFF`                        | `#88B5` |
| `-l`   | Input frame length, `14..1514`                   | 60      |
| `-f`   | Payload pattern: `00`, `FF`, `55`, `AA` or `INC` | `INC`   |
| `-n`   | Frames to send, `1..100`                         | 1       |
| `-w`   | Link wait in `CYCLES21` quanta, `1..10000`       | 10000   |
| `-s`   | Physical ISA slot, `0` or `1`                    | 1       |
| `-p`   | ISA ID port, `#100..#1F0`                        | `#110`  |
| `-b`   | I/O base, `AUTO` or `#200..#3E0`                 | EEPROM  |
| `-v`   | Verbose output                                   | off     |

`-w` counts `CYCLES21` quanta, not exact milliseconds: one quantum is roughly
1..6 ms across Sprinter's supported clock range.

## Behaviour

The source MAC always comes from the card EEPROM. The length in the TX
preamble is `max(input_length, 60)`. A short frame is zero-padded to 60 bytes
and the FIFO is then zero-padded to a DWORD; those padding bytes are not put
on the wire. In `INC` mode the frame number is added to the payload's starting
phase, so a burst can be checked for loss, duplication and reordering.

`EL3.DONE` and the release of the DSS page run on every exit path.

## Examples

```text
EL3TX -d 02:80:19:11:22:33
EL3TX -d FF:FF:FF:FF:FF:FF -l 1514 -f 55 -n 10
EL3TX -d 02:80:19:11:22:33 -t #0800 -w 2000 -v
```

## Exit codes

Success ends with `RESULT OK`. A failure prints the stage, the detailed EL3
code, waitq, base and status, then `RESULT FAIL code=N`. EL3 code 20 is a
finite link timeout.

The DSS exit code follows the shared classification in `HOWTO.TXT`: 1
arguments, 2 hardware, 3 timeout/network, 5 DSS/memory.
