# NETPROF.EXE

`NETPROF.EXE` answers the question "where do the seconds go during network
bring-up". It runs the sequence every network utility runs between printing
its banner and getting its first answer off the wire, and reports how many
whole RTC seconds each stage cost. It is included only in the developer floppy
image.

It exists because on real hardware `PING`, `FTP` and `WGET` all paused for
several seconds before doing any visible work, and nothing in their shipped
output said which stage was responsible.

## Usage

```text
NETPROF [-r] [IPv4]
```

| Argument | Meaning                                                     |
|----------|-------------------------------------------------------------|
| `-r`     | Force a global ISA reset during attach, not the fast path.   |
| `IPv4`   | Address to ARP. Defaults to `NET_GATEWAY`, which is what     |
|          | the utilities ARP anyway.                                    |

Unparsable address text falls back to the gateway. Run `NETCFG -i` first.

## Output

| Line   | Stage                                                      |
|--------|------------------------------------------------------------|
| `[P1]` | Reading the configuration                                  |
| `[P2]` | `DISCOVER`: the 64-word EEPROM read, timed on its own       |
| `[P3]` | The full driver bring-up (`INIT` minus `DISCOVER` is P3-P2) |
| `[P4]` | Waiting for link                                           |
| `[P5]` | The first ARP exchange, with target and attempt count       |
| `[P6]` | A second ARP exchange                                       |
| `[P7]` | Measured RTC ticks per second                               |
| `[P8]` | The cost of 10000 ticks                                     |

`[P2]` also prints the EEPROM slot and whether attach took the `FAST` or
`RESET` path; `[P4]` prints the link wait in quanta.

`DISCOVER` is timed separately from the one `NETDRV.INIT` call the utilities
actually make, so the EEPROM read can be separated from `ACTIVATE` and `INIT`.
`P5` and `P6` were added after the first run showed `P1..P4` all costing zero
seconds on a real Sprinter: the time was going into the first frames on the
wire, not into bring-up.

## Examples

```text
NETPROF
NETPROF 192.168.7.1
NETPROF -r 192.168.7.1
```

## Exit codes

| Code | Meaning                                                    |
|------|------------------------------------------------------------|
| 0    | The whole sequence completed                               |
| 2    | 3C509B not detected                                        |
| 3    | Link or ARP failure                                        |
| 4    | `NET_*` environment missing or invalid; run `NETCFG -i`    |
| 5    | Local failure                                              |

Every run ends with `RESULT OK` or `RESULT FAIL code=N`.
