# Sprinter 3C509B Network Kit

This repository develops a polling-only network kit for the Sprinter DSS and a
3Com EtherLink III 3C509B-TPO in an ISA8 slot.

Version 0.0.1 is now the Stage 3 bootstrap. It adds polling-only, read-only
classic-ISA discovery (`EL3INFO`), a complete EEPROM diagnostic (`EL3EEP`), and
an explicit-range read-only bus diagnostic (`ISAPROBE`). Network commands and
`UNET509B.DLL` will appear only after the required MAME and real-hardware
evidence exists. No EEPROM write or Sprinter IRQ route is implemented.

## Build

Install `sjasmplus`, mtools (`mformat`, `mcopy`, and `mdir`), `zip`, `unzip`,
`iconv`, and Perl. Then run:

```sh
make build
make test-host
make package
make image
```

Generated files are placed under `build/` and `distr/`:

- `build/HELLO.EXE`, `EL3INFO.EXE`, `EL3EEP.EXE`, and `ISAPROBE.EXE` are the
  current DSS programs.
- `distr/sprinter-3c509b.img` is a 1.44 MB FAT12 developer image containing
  all four programs and the runtime documents/configuration.
- `distr/sprinter-3c509b.zip` contains the safe user diagnostic `EL3INFO` and
  excludes `HELLO`, `EL3EEP`, and `ISAPROBE`.

The text files inside IMG and ZIP are flat, strict 8.3 names encoded as CP866
with CRLF line endings. Binary artifacts are copied byte for byte. See
`docs/QUICKSTART_RU.md` for the Russian quick start and
`docs/MAME_STAGE0.md` for developer-only emulator instructions.

## Scope and safety

`specs.md` is the authoritative specification and acceptance log. Stages 2 and
3 remain formally open: the feature request does not replace emulator evidence,
and the physical card has not yet been tested. Sprinter ISA interrupt routing
is intentionally absent; every wait is bounded and EEPROM is read-only.

## License

BSD-3-Clause. The minimal DSS include/macro scaffolding retains attribution to
Roman Boykov; see `LICENSE` and the source headers.
