# ISAPROBE.EXE

`ISAPROBE.EXE` is a read-only dump of an explicitly named range of the
Sprinter ISA-8 window. It exists for the case where a card is not detected and
you need to see what the bus actually returns. It is included only in the
developer floppy image.

It never writes ISA data. It also never guesses: without a complete
`-s` / `-b` / `-n` tuple it prints help and performs no ISA access at all.

## Usage

```text
ISAPROBE -s 0|1 -b #0000..#3FFF -n #0001..#0100
ISAPROBE /?
```

| Option | Meaning                                                      |
|--------|--------------------------------------------------------------|
| `-s`   | Physical ISA slot, `0` or `1`. Required.                     |
| `-b`   | Offset in the ISA window, four hex digits. Required.         |
| `-n`   | Number of bytes to read, `#0001..#0100`. Required.           |

`-b` and `-n` take exactly four hex digits after `#`, so write `#0300`, not
`#300`. `ISAPROBE` does not accept `-p`: it addresses the window directly
rather than going through an ID port.

## Behaviour

`[E0]` echoes the slot, base and count actually used. The range is then dumped
16 bytes per line. Reads are sequential and bounded by `-n`; the ISA window is
closed before the program returns to DSS.

Use only a range you identified beforehand. Reads of unknown hardware can have
side effects, which is exactly why no default range exists and why nothing
here scans.

## Examples

```text
ISAPROBE -s 1 -b #0300 -n #0010
ISAPROBE -s 0 -b #0110 -n #0004
```

## Exit codes

Detailed EL3 status codes are mapped onto the shared DSS classes: 1 arguments
(including an incomplete tuple), 2 hardware, 3 timeout, 5 DSS/memory. Every
run ends with `RESULT OK` or `RESULT FAIL code=N`.
