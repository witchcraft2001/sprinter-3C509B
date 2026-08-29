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
