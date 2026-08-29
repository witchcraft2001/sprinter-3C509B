# Sprinter 3C509B Network Kit

This repository develops a polling-only network kit for the Sprinter DSS and a
3Com EtherLink III 3C509B-TPO in an ISA8 slot.

Version 0.0.1 is the Stage 0 bootstrap. It contains only `HELLO.EXE`, build and
host-side validation, a FAT12 developer image, and a release-pipeline ZIP. It
does not detect, configure, read, or write the network card. Network commands
and `UNET509B.DLL` will appear in later stages after their required MAME and
real-hardware evidence exists.

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

- `build/HELLO.EXE` is the minimal DSS smoke test.
- `distr/sprinter-3c509b.img` is a 1.44 MB FAT12 developer image containing
  `HELLO.EXE` and the Stage 0 documents/configuration.
- `distr/sprinter-3c509b.zip` exercises the user-package pipeline but excludes
  the test-only `HELLO.EXE`.

The text files inside IMG and ZIP are flat, strict 8.3 names encoded as CP866
with CRLF line endings. Binary artifacts are copied byte for byte. See
`docs/QUICKSTART_RU.md` for the Russian quick start and
`docs/MAME_STAGE0.md` for developer-only emulator instructions.

## Scope and safety

`specs.md` is the authoritative specification and acceptance log. Sprinter ISA
interrupt routing is intentionally absent. All future controller access must be
polling-based with finite timeouts, and EEPROM writes are outside the project
scope.

## License

BSD-3-Clause. The minimal DSS include/macro scaffolding retains attribution to
Roman Boykov; see `LICENSE` and the source headers.
