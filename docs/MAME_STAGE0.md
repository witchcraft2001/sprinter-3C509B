# Stage 0 DSS image check in MAME

This document is developer-only and is intentionally absent from both runtime
artifacts. Stage 0 does not use a network provider and performs no NIC I/O.

Build and inspect the image from this repository:

```sh
make image
mdir -i distr/sprinter-3c509b.img ::
```

Start the neighboring MAME checkout with the image in floppy drive 1 and the
3C509B model in ISA slot 1:

```sh
cd ../mame
./mame sprinter \
  -isa1 3c509b \
  -flop1 ../sprinter-3C509B/distr/sprinter-3c509b.img
```

If the local checkout uses a different Sprinter system short name, confirm it
with `./mame -listfull | grep -i sprinter` and change only the `sprinter`
argument. Do not add or connect an IRQ callback.

At the DSS command line, run:

```text
HELLO
```

Record the MAME version, DSS version, exact command, and complete output. The
expected program output is:

```text
3C509B DEV HELLO v0.0.1
RESULT OK
```

This check passed on 2026-08-29 with MAME 0.287 (LP64) and DSS 1.71.64. The
captured output is stored in
[`docs/evidence/stage0-mame-hello-0.0.1.png`](evidence/stage0-mame-hello-0.0.1.png),
with its SHA-256 and test metadata in [`docs/evidence/README.md`](evidence/README.md).
The real Sprinter run remains a separate open acceptance check.
