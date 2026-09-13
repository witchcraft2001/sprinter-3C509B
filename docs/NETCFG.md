# NETCFG.EXE

`NETCFG` manages the transactional `NET_*` environment configuration. It is
the only utility in the kit that opens `NET.CFG`; every other program reads
the published environment. Run it once after boot, and again after any change
to `NET.CFG`.

## Usage

```text
NETCFG
NETCFG -i [-v]
NETCFG -c [-v]
NETCFG -d
NETCFG -v
NETCFG /?
```

| Form         | Meaning                                                    |
|--------------|------------------------------------------------------------|
| (no option)  | Display the currently published values.                    |
| `-i`         | Validate the file and the card, then commit the environment. |
| `-c`         | Validate the file only; no card access, no publishing.     |
| `-c -v`      | Validate the file and also validate the card.              |
| `-d`         | Remove every variable owned by this package.               |
| `-v`         | Detailed file-and-card check without committing.           |

Every run ends with `RESULT OK` or `RESULT FAIL code=N`.

## The configuration file

`NETCFG` reads only `NET.CFG` in the executable directory. It accepts LF or
CRLF, treats whole `#` lines as comments, warns about unknown or repeated
keys, and uses the last value of a repeated key. A malformed or oversized
file, a card error, or an environment error leaves the old environment intact.

The keys are `NET`, `HW`, `IDPORT`, `MAC`, `IP`, `NETMASK`, `GATEWAY`, `DNS1`,
`DNS2`, `NTP`, and `TZ`. `NET` must be `509B`; `HW` is `AUTO` or
`0/#base`/`1/#base`; `IDPORT` is `#100..#1F0` on a 16-byte boundary. An empty
`MAC` uses the read-only EEPROM address. `IP=DHCP` selects DHCP; otherwise it
is the static address and requires `NETMASK`. There is no IRQ key.
`HOWTO.TXT` lists the keys with their accepted forms.

`TZ` is empty for UTC or `[+|-]H`, `[+|-]HH`, `[+|-]H:MM`, or `[+|-]HH:MM`.
The sign defaults to positive; minutes must be exactly `00`, `15`, `30`, or
`45`, and the range is `-12:00..+14:00`. Examples include `+5:30`, `+5:45`,
`+9:30`, `+12:45`, and `-3:30`.

## Where the card actually is

`NET_HW` published after `-i` is not a copy of the file's `HW` key: it is the
card's actual location once discovery succeeds. `HW=AUTO` publishes the slot
and base the auto-probe found; an explicit `HW=0/#base`/`1/#base` publishes
that value unchanged when the card answers there. A pin naming a slot no
adapter answers falls back to the same auto-probe both slots get, and
publishes the location it actually finds, printing
`[W] HW=<old> not usable, probed <new>` first. To make the box re-discover the
card from scratch (for example after moving it), set `HW=AUTO` in `NET.CFG`
and run `NETCFG -i` again, or run `NETCFG -d` to clear the environment
entirely.

In DHCP mode `NETCFG -i` clears old dynamic IP, DNS, server, and lease values.
It does not contact a DHCP server; run `IFUP` next.

## Examples

```text
REN NETSMPL.CFG NET.CFG
NETCFG -c
NETCFG -i -v
NETCFG
NETCFG -d
```

## Failure and exit codes

`RESULT FAIL code=N` is the detailed diagnostic code printed on screen. The
process status (`ERRORLEVEL`, register `B` at `DSS_EXIT`) is a broader class;
the two numbers are deliberately not the same.

For example, `NETCFG -i` showing `RESULT FAIL code=3` has successfully read
and parsed `NET.CFG`, but did not find an accepted 3C509B at the selected
`HW`/`IDPORT`. Run `EL3INFO -v` before changing the configuration. A following
`IFUP` or `PING` may then show `RESULT FAIL code=22`: `NETCFG` did not publish
the required `NET_*` environment after the failed discovery.

Common printed diagnostic codes are:

| `RESULT FAIL code` | Meaning |
|---:|---|
| 3 | No accepted adapter: no ID-sequence response, or Product ID/manufacturer/MAC validation rejected the EEPROM. `EL3INFO` `stage=E3` means the latter. |
| 4 | Controller timer expired during discovery |
| 5 | EEPROM checksum validation failed |
| 6 | Invalid or unusable I/O base |
| 7 | Active controller-window verification failed |
| 8 | ISA window state could not be established or restored |
| 18 | DSS page allocation or release failed |
| 21 | Invalid `NETCFG` command-line arguments |
| 22 | `NET.CFG` missing, unreadable, malformed, oversized, or a key/value invalid |

The `ERRORLEVEL` returned by `NETCFG` is:

| `ERRORLEVEL` | Meaning |
|---:|---|
| 0 | OK |
| 1 | Usage error |
| 2 | Hardware/discovery failure |
| 4 | Configuration failure |
| 5 | DSS local-memory or environment-write failure |

`-i` fails with 2 or 4 when it cannot obtain a MAC for `NET_MAC`. Nothing
downstream works without it, so it reports the failure at that point instead
of succeeding and letting `IFUP` surface the symptom.
