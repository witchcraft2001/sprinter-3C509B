# Sprinter 3C509B Network Kit

This repository develops a polling-only network kit for the Sprinter DSS and a
3Com EtherLink III 3C509B-TPO in an ISA8 slot.

Version 0.0.1 contains the local code for Stages 3–6: read-only classic-ISA
discovery (EL3INFO/EL3EEP), explicit read-only probing (ISAPROBE), polling
register INIT/DONE (EL3REG), and bounded FIFO/controller-loopback testing
(EL3LB), and bounded physical Ethernet TX/RX diagnostics (EL3TX/EL3RX).
Protocol-level network commands and UNET509B.DLL remain future stages. No EEPROM
write or Sprinter IRQ route is implemented.

## Build

Install `sjasmplus`, `z88dk-ticks`, mtools (`mformat`, `mcopy`, and `mdir`),
`zip`, `unzip`, `iconv`, Perl, Node.js and Python 3. Then run:

```sh
make build
make test-host
make package
make image
```

Generated files are placed under `build/` and `distr/`:

- HELLO.EXE, EL3INFO.EXE, EL3EEP.EXE, EL3REG.EXE, EL3LB.EXE, EL3TX.EXE,
  EL3RX.EXE, and
  ISAPROBE.EXE are the current DSS programs under build/.
- `distr/sprinter-3c509b.img` is a 1.44 MB FAT12 developer image containing
  all programs and the runtime documents/configuration. EL3LB, EL3TX, EL3RX
  and EL3REG are developer diagnostics shipped only here.
- `distr/sprinter-3c509b.zip` contains the safe user diagnostic `EL3INFO` and
  excludes developer/test programs.

The text files inside IMG and ZIP are flat, strict 8.3 names encoded as CP866
with CRLF line endings. Binary artifacts are copied byte for byte. See
`docs/QUICKSTART_RU.md` for the Russian quick start and
`docs/MAME_STAGE0.md` for developer-only emulator instructions.

## Scope and safety

specs.md is the authoritative specification and acceptance log. Local code and
documentation do not close a stage: Stages 5/6 still require their combined
MAME matrix, file-backed evidence, and a real Sprinter/3C509B-TPO run. Sprinter
ISA interrupt routing is intentionally absent; every wait is bounded and EEPROM
is read-only.

## License

BSD-3-Clause. The minimal DSS include/macro scaffolding retains attribution to
Roman Boykov. The host-only Z80 core is MIT licensed by Molly Howell; see
`LICENSE`, `THIRD_PARTY.md`, and the source headers.
