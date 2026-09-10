# Third-party test code

`tools/exe-harness/Z80core.js` is Molly Howell's Z80 interpreter, adapted from
the local `sprinter-lha` test harness and used only by host-side tests. It is
distributed under the MIT license in `tools/exe-harness/LICENSE.Z80core`.

Imported source SHA-256:
`44a0398fdf763aca6cd3608777f4b30aa53ceb4d0ec2f7234422ceb44980def0`.

The Z80 core is not linked into DSS executables or included in IMG/ZIP runtime
artifacts.

# Sibling-kit design reuse

`src/apps/ftp.asm` and `src/apps/dlspeed.asm` (Stage 13) are original
implementations against this project's own TCPX/FILE/CONSOLE ABI, but their
control-flow design is adapted from the sibling `sprinter-rtl8019a` kit's
`ftp.asm` and `dlspeed.asm` (BSD-3-Clause, same author): the FTP command
sequence and reply-framing algorithm (`READ_REPLY`/`FIND_LINE`), the
`PARSE_PASV` octet parser, the CLI grammar, and DLSPEED's RTC-edge-aligned
timing technique all follow the sibling's approach. No sibling source lines
were copied verbatim; every routine was rewritten for this codebase's own
registers, memory layout, and transport calls. This reuse is permitted by the
project's own clean-room policy, which restricts to design-reference-only the
GPL DOS packet driver and Linux 3c509 driver, not this BSD-3-Clause sibling.

`src/lib/libman13.asm` is a vendored, byte-identical copy of the Sprinter SDK's
libman 1.3 DLL loader (`sources/libman/docs/libman13/LIBMAN13.ASM`, Module
LIBMAN v1.3, last revision 30.04.2004), taken via the sibling
`sprinter-rtl8019a` kit's own copy of the same file (BSD-3-Clause, same
author's wrapping: `MODULE LIBMAN` + include guard + DSS error diagnostics
around the original loader). `UNET509B.DLL` and `UNETTEST.EXE` (Stage 14) use
it unmodified to load and call any libman 1.3 / L1 DLL, exactly as the sibling
kit's own `UNETRTL.DLL`/`UNETTEST.EXE` do.
