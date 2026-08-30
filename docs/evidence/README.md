# Verification evidence

## Stage 0: MAME HELLO

- Date: 2026-08-29.
- Emulator: MAME 0.287 (LP64).
- DSS: 1.71.64.
- Program/package version: 0.0.1.
- Launcher: `mame_release_v306_25.05.2025/3com.sh` with the generated
  `distr/sprinter-3c509b.img`.
- Screenshot: [stage0-mame-hello-0.0.1.png](stage0-mame-hello-0.0.1.png).
- SHA-256: `22757799eec64c9ba908379241ea9b4437d04793da9f54e76c01c0d02829872c`.

Observed output:

```text
3C509B DEV HELLO v0.0.1
RESULT OK
```

Result: PASS in MAME. This does not replace the real Sprinter run.

## Stage 1: adapter photographs

- Front: [stage1-3c509b-front.png](stage1-3c509b-front.png), SHA-256
  `e2bf608f902b162f5afc80c9da673dd6c11d6987979acf15855717852eb65d84`.
- Back: [stage1-3c509b-back.png](stage1-3c509b-back.png), SHA-256
  `bed4fd9059dc94fe7913b1dce98ad07fc121c30fb891e21f9b71318eb0048c03`.

Visible markings:

- adapter: 3Com EtherLink III `3C509B-TPO`, 10 Mbps;
- assembly revision sticker: `REV B`; obscured assembly-number suffix is not
  treated as evidence;
- PCB: `FAB 02-0020-000 REV A`;
- factory label EA/MAC: `00:20:AF:5D:69:8B`;
- controller marking: 3Com `40-0130-002`.
- the external connector at footprint `J70` appears absent or desoldered in
  both supplied photographs; the red arrows point to this area. This is a
  photographic observation, not a confirmed electrical diagnosis.

The adapter was in transit when the photographs were supplied. Photographs do
not prove EEPROM contents, active I/O/IRQ/PnP resources, checksum validity, or
operation in a Sprinter. On arrival, inspect the `J70` footprint and soldering
before applying power. Physical link/TX/RX testing cannot pass without a sound
10BASE-T connector. The remaining configuration checks must be read-only.

## Stage 3: local code and host regressions

- Date: 2026-08-30.
- Version: 0.0.1 (unchanged).
- Assembler: sjasmplus 1.22.0.
- Z80 runner: `z88dk-ticks` from the local z88dk installation.
- Reproduction: `make clean && make build && make test-host && make package && make image`.

Observed host results:

```text
EL3INFO.EXE: DSS header, boundary, runtime-BSS and result markers passed
EL3EEP.EXE: DSS header, boundary, runtime-BSS and result markers passed
ISAPROBE.EXE: DSS header, boundary, runtime-BSS and result markers passed
Stage 3 source contract: read-only EEPROM, polling timeout, ISA8 ordering, no IRQ passed
Stage 3 ASM vectors: LFSR[255], 31 bases, EEPROM/MAC/checksums, and CLI bounds passed
Host tests passed
```

The ASM vectors execute the production LFSR, base encoding, EEPROM parsing,
MAC ordering, checksum, and command-line routines. Packaging checks cover all
EXE headers and the `0xC000` limit, runtime BSS exclusion, strict 8.3 names,
ZIP/IMG membership, CP866/CRLF text, and byte-identical binaries.

No complete Stage 3 MAME or physical-card result is claimed here. The emulator
matrix (both slots, bases `#200/#300/#3E0`, no card, invalid parameters, and
full EEPROM dump) and the real 3C509B EEPROM/MAC comparison remain mandatory
before Stage 3 can close. The reproducible procedure and report template are
[documented separately](../STAGE3_TESTING_RU.md); their presence is not test
evidence. Individual completed MAME cases are recorded below.

## Stage 4: local register-core and mock regressions

- Date: 2026-08-30.
- Version: 0.0.1 (unchanged).
- Reproduction: `make clean && make test-host package image`.

Observed local results:

```text
Stage 4 host contract: provider split, cycle timeout, polling INIT/DONE, snapshot and EL3REG passed
Stage 4 ASM mock: ISA8 order, ABI, commands/windows, CIP/recovery, INIT/DONE x100, snapshot v1/60 and CLI bounds passed
```

The executable mock verifies low/high ISA8 ordering, command encoding, windows
0–6, the exact INIT/DONE trace and MAC order, immediate/delayed/permanent CIP,
100 complete cycles, snapshot v1/60 and `-n` bounds 0/1/100/101. Static host
checks reject CTC/FRAMES/RTC dependencies, EEPROM writes, IRQ routing and DSS
calls from the register/provider path. This is reproducible local evidence only.

No MAME or physical-card Stage 4 pass is claimed. The earlier `FAIL code=10`
was identified as a driver-side threshold readback expectation: command value
`07FF` is represented in Window 5 with DWORD granularity as `07FC`. The required
matrix and physical procedure are in
[STAGE4_TESTING_RU.md](../STAGE4_TESTING_RU.md), with
[STAGE4_TEST_TEMPLATE.md](STAGE4_TEST_TEMPLATE.md) for evidence capture.

## Stage 3: MAME timer failure (superseded build)

- Date: 2026-08-30.
- Slot/ID port: slot 1, `#110`.
- Screenshot: [stage3-mame-slot1-timer-failure.png](stage3-mame-slot1-timer-failure.png).
- SHA-256: `40f473a6b999ff8778e62be75eb43b3ab01e509c497fb27b60d9108d0e3e27f5`.

Observed output ended with:

```text
ERROR stage=E1 code=4 ticks=0 slot=1 idport=0110 base=0000 status=0000
RESULT FAIL code=4
```

Result: FAIL. The run proved that the first Stage 3 implementation incorrectly
used the Spectrum-compatible `FRAMES` location, which DSS does not advance.
A later diagnostic build observed CTC0 without writing it; the current build
supersedes that too and uses the independent CYCLES21 quantum. This record is
retained as historical regression evidence and is not a current MAME pass.

## Stage 3 M02: MAME slot 1, EEPROM base

- Date: 2026-08-30.
- Emulator: MAME 0.287, unchanged 3C509B model.
- Image SHA-256: `1056482336398e37f697bbf049e8c480d5065362a3094138d4ec6349541a4aae`.
- Command: `EL3INFO -v -s 1 -p #110 -b AUTO`.
- Screenshot: [M02-slot1-auto.png](M02-slot1-auto.png).
- Screenshot SHA-256: `5d7a0894957b086a47fe663c685b3540a7fd89f4847002a659784634bab62ef5`.

Observed output:

```text
3C509B EL3INFO v0.0.1
[E0] SLOT=1 IDPORT=0110
[E1] PRODUCT=9550 IO=0300
[E2] MAC=02:60:8C:39:03:F9
[E3] IRQ=3 (not used by Sprinter)
[E4] MFG=6D50 ADDR=0010 RESOURCE=3000
[E5] CHECKSUM=F821 SECONDARY=A100
RESULT OK
```

Result: PASS for matrix case M02 only. This confirms the fixed timer proceeds
past reset and that discovery, EEPROM validation and EEPROM-base activation
complete in MAME slot 1. It does not close the remaining MAME or hardware cases.

## Stage 3 M01: MAME slot 0, EEPROM base

- Date: 2026-08-30.
- Emulator: MAME 0.287, unchanged 3C509B model.
- Image SHA-256: `1056482336398e37f697bbf049e8c480d5065362a3094138d4ec6349541a4aae`.
- Command: `EL3INFO -v -s 0 -p #110 -b AUTO`.
- Screenshot: [M01-slot0-auto.png](M01-slot0-auto.png).
- Screenshot SHA-256: `4901fe9297a0dec060e2685a9dd0947fbcdbc4e149627d1cccb1e3a64523bc21`.

Observed output:

```text
3C509B EL3INFO v0.0.1
[E0] SLOT=0 IDPORT=0110
[E1] PRODUCT=9550 IO=0300
[E2] MAC=02:60:8C:88:87:D3
[E3] IRQ=3 (not used by Sprinter)
[E4] MFG=6D50 ADDR=0010 RESOURCE=3000
[E5] CHECKSUM=F821 SECONDARY=A100
RESULT OK
```

Result: PASS for matrix case M01 only. M01 and M02 together confirm read-only
discovery and EEPROM-base activation in both emulated ISA slots. MAME assigns
different locally administered MAC addresses to the two card instances: slot 0
has `02:60:8C:39:03:F9`, while slot 1 has `02:60:8C:88:87:D3`.
Explicit bases and the remaining negative/dump cases are still open.

## Stage 3 M03–M05: MAME slot 0, explicit bases

- Date: 2026-08-30.
- Emulator: MAME 0.287, unchanged 3C509B model.
- Image SHA-256: `1056482336398e37f697bbf049e8c480d5065362a3094138d4ec6349541a4aae`.
- Commands: `EL3INFO -s 0 -p #110 -b #200`, then `#300`, then `#3E0`.
- Screenshot: [M03-M05-slot0-explicit-bases.png](M03-M05-slot0-explicit-bases.png).
- Screenshot SHA-256: `58b2e85b633736939091cee13b9c0d3c623c9aeba83f24346a640c8dd13ddd6e`.

Observed results:

```text
SLOT=0 IDPORT=0110  PRODUCT=9550 IO=0200  MAC=02:60:8C:39:03:F9  RESULT OK
SLOT=0 IDPORT=0110  PRODUCT=9550 IO=0300  MAC=02:60:8C:39:03:F9  RESULT OK
SLOT=0 IDPORT=0110  PRODUCT=9550 IO=03E0  MAC=02:60:8C:39:03:F9  RESULT OK
```

Result: PASS for matrix cases M03, M04 and M05. Each activation is temporary;
the matching MAC in all three runs confirms that the EEPROM identity did not
change. Slot 1 explicit-base cases M06–M08 remain open.

## Stage 3 M06–M08: MAME slot 1, explicit bases

- Date: 2026-08-30.
- Emulator: MAME 0.287, unchanged 3C509B model.
- Image SHA-256: `1056482336398e37f697bbf049e8c480d5065362a3094138d4ec6349541a4aae`.
- Commands: `EL3INFO -s 1 -p #110 -b #200`, then `#300`, then `#3E0`.
- Screenshot: [M06-M08-slot1-explicit-bases.png](M06-M08-slot1-explicit-bases.png).
- Screenshot SHA-256: `a1b9be84aeba36540b7e685c84933d1d46655338009c813737c3b5b0d00ad205`.

Observed results:

```text
SLOT=1 IDPORT=0110  PRODUCT=9550 IO=0200  MAC=02:60:8C:88:87:D3  RESULT OK
SLOT=1 IDPORT=0110  PRODUCT=9550 IO=0300  MAC=02:60:8C:88:87:D3  RESULT OK
SLOT=1 IDPORT=0110  PRODUCT=9550 IO=03E0  MAC=02:60:8C:88:87:D3  RESULT OK
```

Result: PASS for matrix cases M06, M07 and M08. Together M01–M08 confirm
discovery in both emulated ISA slots and AUTO/explicit activation at every
required test base. Negative cases and the full EEPROM dump remain open.

## Stage 3 M10: MAME slot 1, card absent

- Date: 2026-08-30.
- Emulator: MAME 0.287, tested slot configured without a 3C509B.
- Image SHA-256: `1056482336398e37f697bbf049e8c480d5065362a3094138d4ec6349541a4aae`.
- Command: `EL3INFO -s 1 -p #110 -b AUTO`.
- Screenshot: [M10-slot1-absent.png](M10-slot1-absent.png).
- Screenshot SHA-256: `13c5ea9b4585f1218bcda1df84bf248f20f4f4703643c7507dd85c6afdf0016e`.

Observed output:

```text
[E0] SLOT=1 IDPORT=0110
ERROR stage=E3 code=3 ticks=18 slot=1 idport=0110 base=0000 status=0000
RESULT FAIL code=3
```

Result: PASS for negative matrix case M10. Absence is reported explicitly and
control returns to DSS after a finite wait. The slot 0 absence case M09 remains
open.

## Stage 3 M09: MAME slot 0, card absent (user report)

- Date: 2026-08-30.
- Command: `EL3INFO -s 0 -p #110 -b AUTO` with
  `MAME_3C509B_SLOT=0 MAME_3C509B_CARD=absent`.
- Result: the user reports a successful negative test with `RESULT FAIL code=3`.
- Screenshot/log: not captured; this case is recorded as user-reported evidence
  and should be repeated if a file-backed artifact is required.
