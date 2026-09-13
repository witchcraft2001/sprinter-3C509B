# EL3EEP.EXE

`EL3EEP.EXE` dumps all 64 words of a 3C509B EEPROM, read-only. It is the
instrument for inspecting a jumperless card's stored base, IRQ and media
settings without a DOS machine and the vendor's setup utility, and for
diagnosing a card that discovery rejects. It is included only in the developer
floppy image.

Nothing in this kit ever writes the EEPROM, `EL3EEP` included.

## Usage

```text
EL3EEP [-s 0|1] [-p #100..#1F0]
EL3EEP /?
```

| Option | Meaning                                                      |
|--------|--------------------------------------------------------------|
| `-s`   | Physical ISA slot, `0` or `1`. Default `1`.                  |
| `-p`   | ISA ID port, `#100..#1F0` on a 16-byte boundary. Default `#110`. |

## Behaviour

`[E0]` echoes the slot and ID port actually used. `[E1]` introduces the dump
of words `00..3F`, eight per line, so one photograph of the screen carries the
complete evidence from a real card. `[E2]` confirms that the IDs, MAC and both
checksums validated.

A rejected image is the whole point of running this on an unknown card, so
when validation is what failed, the words are printed exactly as they were
read, followed by an `[E3]` diagnostic line:

```text
[E3] FAIL=n PRI=stored/computed SEC=stored/computed
```

`PRI` and `SEC` are the primary (word `0F`) and secondary (word `17`) checksum
words as stored on the card and as computed from the dump. `FAIL=n` names the
check that rejected the card:

| n | Check that failed              |
|---|--------------------------------|
| 1 | Product ID (expected `0x9550` or `0x9050`) |
| 2 | 3Com manufacturer ID           |
| 3 | MAC address                    |
| 4 | Primary EEPROM checksum        |
| 5 | Secondary EEPROM checksum      |

An empty slot reads every word as `FFFF` and fails before this point, at
discovery.

Two product IDs are accepted: `0x9550` (a 3C509B-TPO, RJ-45 only) and `0x9050`
(a 3C509B-TP, RJ-45 plus an unused AUI connector). The two boards share the
EEPROM layout, the manufacturer ID, both checksum lanes and byte-identical
media/config words `08`/`09`/`0D`; beyond the product ID their dumps differ
only in per-unit data (MAC, date code, checksums). A product ID that is
neither of these two verified values is still rejected as `FAIL=1`: this is a
short allow-list built from real hardware, not a bitmask that would also
accept unrelated boards.

## Examples

```text
EL3EEP
EL3EEP -s 0
EL3EEP -s 1 -p #150
```

## Exit codes

Detailed EL3 status codes are mapped onto the shared DSS classes: 1 arguments,
2 hardware, 3 timeout, 5 DSS/memory. Every run ends with `RESULT OK` or a
diagnostic line plus `RESULT FAIL code=N`, where the failure line carries the
stage, code, waitq, slot, ID port and controller status.
