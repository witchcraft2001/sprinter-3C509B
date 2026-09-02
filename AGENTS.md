# Repository instructions

## Authority and staged delivery

- `specs.md` is the authoritative specification, roadmap, and acceptance log.
- Implement stages in order. Do not skip a stage or mark it complete without
  reproducible evidence for every mandatory acceptance item.
- When a stage creates executable code, both MAME and real Sprinter checks are
  required before advancing. Keep their boxes open until actual output, logs,
  dumps, or pcaps are recorded.
- End every code iteration with `make test-host package image`. Fix failures
  before handing off the iteration.

## Verification ownership and user communication

- Automated tests, builds, packaging, image generation, and their failure
  diagnosis are the agent's responsibility. Run them internally before
  handing off code; do not ask the user to run them or report their output
  unless the user explicitly requests that information.
- When the user asks for testing instructions, provide only the manual
  MAME/Sprinter procedure, expected on-screen behavior, and evidence to
  collect. Keep automated commands out of that user-facing checklist.

## Hardware and clean-room constraints

- Sprinter ISA IRQ lines are intentionally not connected. Never add IRQ routing
  in this repository or in MAME, and never connect a 3C509B `irq*_callback` to
  the Sprinter CPU.
- The 3C509B driver is polling-only. Every wait loop must have a finite timeout
  and must return an explicit status code on expiry.
- Nestor's DOS packet driver and the Linux 3c509 driver are GPL clean-room
  references only. Record observed behavior or pseudocode, then implement from
  the 3Com documentation. Never copy their source code into this BSD project.
- EEPROM access is read-only. Do not add EEPROM writes or persistent card
  reconfiguration. Default probing must be bounded and safe for other ISA
  devices.
- On real hardware, start with read-only discovery, use documented ports only,
  avoid blind scans, and record the card/slot/base before testing. A timeout or
  unexpected status must close the ISA window and return control to DSS.

## Project and target layout

- Keep shared constants and ABI declarations in `src/include/`, reusable code
  in `src/lib/`, applications in `src/apps/`, `UNET509B.DLL` in `src/dll/`,
  templates in `config/`, user/developer text in `docs/`, examples in
  `examples/`, and host/build utilities in `tools/`.
- Assemble Z80 sources with `sjasmplus`.
- A normal DSS EXE starts with a complete 128-byte header at `0x8080`; code and
  the entry point start at `0x8100`. Keep the image and all resident data below
  `0xC000`.
- The Sprinter ISA window occupies `0xC000..0xFFFF`. Do not call DSS or touch DSS
  system pages while that window is open. For 16-bit ISA registers, access the
  low byte immediately before the high byte.
- Do not put zero-filled runtime BSS or packet buffers into EXE files. In
  particular, no EXE BSS may extend above or overlap `0xC000`; allocate/map DSS
  pages for large runtime storage.

## Public configuration and artifacts

- `NET=509B` is the common backend selector. The public DLL name is
  `UNET509B.DLL`. Hardware configuration keys are `HW`, `IDPORT`, and `MAC`;
  there is no IRQ setting.
- `tools/artifacts.sh` is the single manifest for both IMG and ZIP. Every
  shipped name must be a unique, case-insensitive, uppercase 8.3 name.
- Convert shipped text from UTF-8/Markdown to plain CP866 with CRLF. Copy EXE,
  DLL, and other binaries byte for byte.
- Developer/test programs belong in the FAT12 IMG. Never put test programs,
  host scripts, objects, listings, dumps, or developer-only MAME documents in
  the release ZIP.
- Preserve neighboring MAME changes. Audit before editing and never discard or
  overwrite unrelated work.

## Assembly and diagnostics

- Use guarded include files, modules for non-trivial units, uppercase mnemonics,
  descriptive labels, and comments for hardware ordering or timing—not for
  restating instructions. Keep constants centralized rather than embedding
  unexplained literals.
- Public routines document inputs, outputs, clobbers, and carry/status behavior.
  Use explicit, stable status codes; do not infer failure solely from printed
  text.
- Diagnostics use stable stage codes such as `[E0]` and end with an unambiguous
  `RESULT OK` or `RESULT FAIL`. Timeout reports include the stage, elapsed
  ticks, selected slot/base, relevant status, and target when applicable.

## Commits and workspace hygiene

- Make small, logically complete commits with imperative subjects. Mention the
  stage and the verification evidence in the commit body when appropriate.
- Do not commit `build/`, `distr/`, editor files, captures containing private
  traffic, or credentials. Do not rewrite, reset, or delete unrelated user
  changes.
