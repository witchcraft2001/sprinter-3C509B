# Verification evidence

## Stage 9: local UDP/TFTP regressions

- Date: 2026-09-01.
- Version: 0.0.1 (unchanged).
- Reproduction: `git diff --check`, `make clean`, then
  `make test-host package image`.

The clean run passed executable UDP checksum/bounds and TFTP framing vectors,
90 actual-EXE scenarios, writable DSS file/error injection, deterministic
loss/duplicate/reorder/unknown-TID behavior, and raw responder/pcap unit tests.
The final artifacts are:

- IMG: `f6eaaf4424092d112c28436f6fb3acc09a5a1cfa2494c407fe5f8a7a899ca06c`.
- ZIP: `9f428a5cf1e7a2981066f9ab70740ec39016b5e52fdd41412f06cd03f26b2239`.
- UDPTEST.EXE: `4f3ecc3948e02c9bcefc4e51650f9e8ab1eef89c1634adb62f519817da8a7d4c`.
- TFTP.EXE: `6051051370321e68ea06e30fc72922a1420ac41b6bb3066877a87bea7de5d9bb`.

This is local automated evidence only. No Stage 9 MAME or physical-card PASS
is claimed. Use [STAGE9_TEST_TEMPLATE.md](STAGE9_TEST_TEMPLATE.md) and the
single-session runbook before checking either gate.

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

- Date: 2026-08-31.
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

## Stage 5: local FIFO/controller-loopback regressions

- Date: 2026-08-30.
- Version: 0.0.1 (unchanged).
- Reproduction: make clean, then make test-host package image.

Observed local results:

    Stage 5 host contract: FIFO provider/core, bounded polling/recovery, loopback, EL3LB and memory/artifacts passed
    Stage 5 ASM mock: FIFO layout/timeouts, TX recovery gating, RX consume/distinct queues, loopback verify, counters, ABI and CLI passed

Final local artifacts after the clean run:

- `sprinter-3c509b.img`: `08d40cb8fea37b544f7b9ffb781e0d7b569a8a496b032136b7ec9cdd031d0951`.
- `sprinter-3c509b.zip`: `66b974c312d78d29ffc59684b3a1540382ca1fc2300b473b0a969cbc5fd63f96`.
- `EL3LB.EXE`: `4e2bed9f20ee8cc99f92331fc326b848f66e845c80656685fed1151b50e3328b` (6732 bytes).

The executable mock covers FIFO sizes 64/68/1520, exact preamble and padding,
immediate/delayed/1000-waitq TX, read-peek/write-pop, bounded
jabber/underrun/collision recovery and failed-recovery retransmit blocking,
RX error/size/pad/discard, distinct queues of 2 and 10 packets, positive and
negative controller-loopback bit #2000 verification, counters, snapshot v1/60,
CLI bounds and IX/IY preservation. Static checks reject FIFO high-byte offsets,
direct ISA access from the core, masked DSS release errors, DSS calls in
low-level paths, IRQ routing, EEPROM writes and packet BSS in EL3LB.EXE.

This is reproducible local evidence only. No Stage 5 MAME or physical-card PASS
is claimed. MAME fault injection for underrun/jabber/bad RX is unavailable in
the selected repository scope and remains an open blocker. Use
[STAGE5_TESTING_RU.md](../STAGE5_TESTING_RU.md) and
[STAGE5_TEST_TEMPLATE.md](STAGE5_TEST_TEMPLATE.md) for those runs.

The Stage 5 hashes above predate the Stage 6 actual-EXE harness. That harness
found that production `OPEN_FIFO` did not preserve the caller's byte count;
the current final Stage 5/6 artifact hashes supersede them below.

## Stage 6: local actual-EXE and host network regressions

- Date: 2026-08-31.
- Version: 0.0.1 (unchanged).
- Reproduction: `make clean`, then `make test-host package image`.
- Optional separate stress: `make test-exe-stress`.

Observed automated results:

    Stage 6 ASM: CRC32, DSS exit mapping and EL3TX/EL3RX CLI defaults/boundaries passed
    Stage 6 host contract: API, CLI, lifecycle, CRC32, actual-EXE harness, network helper and artifacts passed
    Actual DSS EXE harness: 119 header, EL3LB, TX/RX vector, CLI, link, filter, CRC32 and cleanup checks passed
    Ethernet helper: classic-pcap lengths, patterns, padding, burst order and no-FCS checks passed
    MAME launcher: named interface validation and slot-specific pcap cfg passed
    EL3LB actual-EXE stress: 100 runs, 5200 exact loopback frames passed

Final local artifacts:

- `sprinter-3c509b.img`:
  `939deaf7ebc9e9c5b46fa7220175954d09d79f1703454c3ac46a9ec7792f7f77`.
- `sprinter-3c509b.zip`:
  `97e3d2951851ca80457a4af7b764738681b495f07d309250f40672cd1bb9512d`.
- `EL3LB.EXE`:
  `1941276a3bf0cebf57c5d8aa8644d4d035eeefb2963200764bfe5f83a94fefaa`.
- `EL3TX.EXE`:
  `d2690e6a7fc42b009da49241b92ff3d25d04b086bb46889153e5e055ee180481`.
- `EL3RX.EXE`:
  `a4b0f975e76c853a34f31248e5edf4a00aecb2e976761e46ccab663308151d14`.

The final IMG contains EL3TX/EL3RX and their CP866/CRLF help. The ZIP remains
unchanged in scope and contains neither diagnostic. Actual-EXE tests exercise
the exact IMG binaries, including 52-frame `EL3LB -n 1`, exact TX preamble,
software/wire padding, RX consuming discard, individual+broadcast filtering,
foreign-unicast rejection, CRC32, delayed/down link, adjacent 16-bit register
cycles, common DSS exit mapping and cleanup.

This local run is host evidence. Partial Stage 5/6 MAME pcaps are imported
below, but no complete MAME matrix or real-card PASS is claimed. The combined
manual session remains open in
[STAGE6_TEST_TEMPLATE.md](STAGE6_TEST_TEMPLATE.md).

## Stage 5/6: imported partial MAME evidence

The already captured files under `evidence/stage56/` are retained as evidence
rather than rerunning their cases. `sha256.txt` identifies the Stage 6 IMG and
three EXEs; `mame-listnetwork.txt` records the named `feth0`/`feth1`
interfaces; `mame-slot1.log` records a 425-second MAME run at 100% speed.

The four classic pcaps each contain one Ethernet frame with caplen=wirelen=60,
so no FCS is present. `tx-14.pcap` and `tx-14-filtered.pcap` contain destination
`66:65:74:68:00:01`, source `02:60:8C:88:87:D8`, EtherType `88B5`, and zero
software padding. `rx-60.pcap` and `rx-60-retry.pcap` contain the reverse test
direction with an incrementing payload through byte `2D`.

These files prove those byte-exact single-frame TX/RX cases only. The workspace
contains no corresponding Stage 5/6 console screenshots, and the remaining
slot/base/burst/filter/link matrix is not represented. Therefore neither the
full MAME matrix nor real-card acceptance is marked complete.

## Stage 7: local protocol and actual-EXE regressions

- Date: 2026-08-31.
- Version: 0.0.1 (unchanged).
- Reproduction: syntax/unit checks, `git diff --check`, `make clean`, then
  `make test-host package image`.

Observed automated results:

    Stage 7 ASM: checksum, ARP framing/routing/cache and DHCP/config vectors passed
    NETDRV ASM: ABI preservation and NONE/WIN1/WIN2 buffer boundaries passed
    Stage 7 host contract: NETDRV ABI, memory, protocols, EXEs, UNET sync and artifacts passed
    Stage 7 actual EXE: 67 NETCFG/IFUP/DHCP/ARP, rollback, ABI boundary and cleanup checks passed
    Stage 7 responder: exact ARP and DHCP framing/checksums passed

Final deterministic artifacts:

- `sprinter-3c509b.img`:
  `bcf32187b3666abcba7f7d991499b785cfed740a7c63cfd3e03f6932557092bd`.
- `sprinter-3c509b.zip`:
  `03dc88cbfde4e0b77bacbcb34d3a50df64bf5c6c5d5f58291480596c6caba3d8`.
- `NETCFG.EXE`:
  `ec32cd363eeadbc2fd53e44ae0767a8d454858eeb61316002e20e61d94b1edc5`.
- `IFUP.EXE`:
  `02a64ceb377c178d487173d101bd37293467a1da07f9d8a1f02ec6ea985f0594`.
- `ARP.EXE`:
  `f22f4eae1e86b6433f1ff5cc432cc63f2bb36cd6f6c9fef70fd07a6919704b8f`.

The exact IMG binaries cover every NETCFG mode, LF/CRLF, missing/invalid/
oversized input, AUTO and explicit hardware, MAC override, ENV rollback,
static/link failure, DHCP ACK/retry/NAK/drop and malformed XID/chaddr/cookie/
options/checksum/L2 destination, plus ARP neighbor/gateway/broadcast/unknown/
malformed paths, strict ENV bounds, timeout diagnostics and Esc/Ctrl-C cancel.
The harness rejects leaked files, pages, ISA windows, and unknown DSS calls.

The mandatory MAME gate was subsequently completed with named `feth0/feth1`
interfaces, screenshots and classic pcaps. See
[`STAGE7_MAME_2026-08-31.md`](STAGE7_MAME_2026-08-31.md). Real-card evidence
remains open without blocking Stage 8.

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
