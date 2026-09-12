#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage12.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/wget.sym" --raw="$tmp_dir/WGET.EXE" \
  "$repo_root/src/apps/wget.asm" >"$tmp_dir/assembly.log"

# WGET loads at 4080h and, in the standard layout, owns WIN1+WIN2 outright. The
# image is code and rodata; the runtime data area begins 2 KiB above PAGE_BASE
# (8800h, memory.inc's S12_IMAGE_LIMIT), so that is what bounds it -- crossing
# it overwrites buffers silently.
size="$(wc -c < "$tmp_dir/WGET.EXE" | tr -d ' ')"
[ "$size" -le $((0x8800 - 0x4080)) ]
[ "$(od -An -tx1 -N4 "$tmp_dir/WGET.EXE" | tr -d ' \n')" = "45584501" ]
[ "$(od -An -tu2 -j16 -N2 "$tmp_dir/WGET.EXE" | tr -d ' \n')" = "16640" ]
# Header stack: the top of WIN2, a whole window clear of the image.
[ "$(od -An -tu2 -j20 -N2 "$tmp_dir/WGET.EXE" | tr -d ' \n')" = "49136" ]
# The data area starts 2 KiB above PAGE_BASE (WGET_LAYOUT): two 1536-byte frame
# staging buffers, which have to hold a whole 1514-byte Ethernet frame at MSS
# 1460, then the 3 KiB disk buffer. Everything from the pending queue up is
# where it was before the shift.
grep -Fq 'S12_IMAGE_LIMIT: EQU 0x00008800' "$tmp_dir/wget.sym"
grep -Fq 'STAGE9_TX_BUFFER: EQU 0x00008800' "$tmp_dir/wget.sym"
grep -Fq 'STAGE9_RX_BUFFER: EQU 0x00008E00' "$tmp_dir/wget.sym"
grep -Fq 'STAGE9_FILE_BUFFER: EQU 0x00009400' "$tmp_dir/wget.sym"
grep -Fq 'S11_PENDING0: EQU 0x0000A000' "$tmp_dir/wget.sym"
grep -Fq 'W12_STATE_BASE: EQU 0x0000AD20' "$tmp_dir/wget.sym"
# Top of the claimed page, never WIN1: BIOS WIN_MOVE destroys a WIN1 stack on
# the first scrolled console line.
grep -Fq 'S10_RUNTIME_STACK_TOP: EQU 0x0000BFF0' "$tmp_dir/wget.sym"
# Resident below the load address, 16 KiB clear of every stack.
grep -Fq 'S10_COMMAND_BUFFER: EQU 0x00004000' "$tmp_dir/wget.sym"

echo "Stage 12 ASM: WGET header, WIN1 image limit, WIN2 page stack and non-overlapping 5 KiB layout passed ($size bytes)"
