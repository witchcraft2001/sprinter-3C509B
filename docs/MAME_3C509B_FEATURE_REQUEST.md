# 3C509B ISA8 accuracy follow-up for MAME 0.287

Status on 2026-08-30: the neighbouring MAME worktree implements the differences
listed below, including Read Zero Mask polarity, timed reset/CIP, threshold
readback, FIFO/TX/RX behaviour and save-state support. This document records the
review baseline and reproduction scenarios; it is not a list of currently
missing Stage 4 features. Reproducible guest and real-card evidence is still
required before the corresponding acceptance items can be closed.

## Tested snapshot and scope

This request is based on MAME 0.287 at commit
`cd34cb6a94434e15270550102ad94798f7650621`. The existing device already has
useful classic-ID activation, all 31 legacy I/O bases, ISA8 low/high latches,
lower-byte FIFO access, explicit RX discard, dword TX padding, and save-state
fields. No MAME source change is included in this repository.

The target guest is Sprinter DSS using a polling-only 3C509B driver. Sprinter
ISA IRQ lines are intentionally not connected. Please do not connect any
3C509B `irq*_callback` (or a generic ISA IRQ callback) to the Sprinter CPU.
An asserted internal card IRQ may remain modelled for other ISA hosts, but it
must not become a Sprinter dependency.

## Confirmed differences from 3Com 09-0398-002B

1. Global-reset AUTOINIT is scheduled for 300 us; the documented maximum is
   310 us. A guest that waits the documented interval should be accepted.
2. An ID-port read while the EEPROM timer is active can shift the previous
   word. The new word should not become readable, and stale shift state should
   not advance, until the read operation completes.
3. Read Zero Mask polarity is reversed. A set mask bit makes that Status source
   visible; a clear bit reads it as zero.
4. Window 1 Timer is permanently `FF`; it should model the 3.2 us saturating
   counter sufficiently for timeout/diagnostic software.
5. RX/TX reset applies important state changes immediately and uses a generic
   CIP delay. RX reset does not restore all documented disable/filter/threshold
   defaults, and TX reset does not terminate every pending/error state.
6. A successful transmit requested with the Notify preamble bit produces TX
   Status `80`; the completed entry must also retain Notify (`C0`).
7. The 31-entry TX Status stack silently drops its oldest entry on overflow.
   Hardware reports overflow and disables TX until recovery.
8. TX allocation/accounting does not cover the complete preamble plus
   dword-rounded packet allocation after launch. Multiple queued packets and
   representative error completions are not modelled.
9. RX completion may leave RX Early asserted simultaneously. RX Complete must
   mask RX Early for the completed packet.
10. Configuration Control POR capability bits and link/media state still need
    comparison with a real 3C509B-TPO trace.
11. RX uses eight fixed packet slots rather than the byte-addressed FIFO
    partition; concurrent receive staging needs a back-to-back regression.
12. EEPROM erase/write paths exist in the model. They are not requested by the
    Sprinter project and must not be needed for any test scenario below.

## Reproduction scenarios

Use `-isa0 3c509b` and `-isa1 3c509b` in separate Sprinter runs. Keep the card
in "Real (ID sequence required)" mode and run the guest diagnostics from the
Stage 3 FAT12 image.

1. Run `EL3INFO -s N -p #110 -b #200`, then repeat with `#300` and `#3E0`.
   Each run sends the 255-byte `FF..98` sequence, performs a bounded reset,
   reads EEPROM, activates the requested base, and verifies Window 0 IDs.
2. Run `EL3INFO -v -s N -p #110 -b AUTO`. Compare Product `9550`, Manufacturer
   `6D50`, MAC byte order, address/resource words, and both checksum words.
3. Run `EL3EEP -s N -p #110` and verify all words `00..3F`; issue debugger
   reads during the 170 us EEPROM interval to confirm that stale data does not
   shift.
4. Remove the card and repeat `EL3INFO`; it must return a bounded failure, not
   hang. Invalid, out-of-range, or misaligned ID-port arguments must fail in
   the guest CLI before ISA access. A different valid aligned ID port is not a
   negative case: the classic selector writes may legitimately move the card
   to that port.
5. For later controller regressions, queue 31/32 notified TX completions, use
   60/61/62/63-byte FIFO payloads, and inject two and ten back-to-back RX
   packets. Check write-to-pop TX Status, overflow/TX-disable behavior, dword
   accounting, RX Early masking, and exactly one RX Discard per packet.
6. Save and restore state during ID EEPROM busy, CIP, queued TX, and two queued
   RX packets; the operation and latch state must resume deterministically.

Expected diagnostics always end with `RESULT OK` or `RESULT FAIL code=N`.
Timeout lines include stage, elapsed CYCLES21 `waitq`, slot/base, and status.

## Suggested acceptance

- Device-level tests cover the timing, mask polarity, reset defaults, TX
  status/overflow, FIFO allocation, RX Early masking, back-to-back RX, and
  save-state cases above.
- Sprinter runs pass in both ISA slots and at `0200`, `0300`, and `03E0`.
- The Sprinter machine configuration contains no ISA IRQ-to-CPU routing.
