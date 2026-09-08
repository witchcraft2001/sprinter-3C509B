#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage13.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/ftp.sym" --raw="$tmp_dir/FTP.EXE" \
  "$repo_root/src/apps/ftp.asm" >"$tmp_dir/ftp-assembly.log"
sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/dlspeed.sym" --raw="$tmp_dir/DLSPEED.EXE" \
  "$repo_root/src/apps/dlspeed.asm" >"$tmp_dir/dlspeed-assembly.log"

# Both load at 4080h and, in the standard layout, own WIN1+WIN2 outright. The
# image is code and rodata; PAGE_BASE (8000h) is where the runtime data area
# begins, so that is what bounds it -- crossing it overwrites buffers silently.
ftp_size="$(wc -c < "$tmp_dir/FTP.EXE" | tr -d ' ')"
[ "$ftp_size" -le $((0x8000 - 0x4080)) ]
dlspeed_size="$(wc -c < "$tmp_dir/DLSPEED.EXE" | tr -d ' ')"
[ "$dlspeed_size" -le $((0x8000 - 0x4080)) ]

for exe in FTP DLSPEED; do
  [ "$(od -An -tx1 -N4 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "45584501" ]
  [ "$(od -An -tu2 -j16 -N2 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "16640" ]
  # Header stack: the top of WIN2, a whole window clear of the image.
  [ "$(od -An -tu2 -j20 -N2 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "49136" ]
done

# FTP: two real TCP contexts (STAGE13_LAYOUT), not WGET's single-channel fold.
grep -Fq 'S11_CONTEXT1: EQU 0x0000AD18' "$tmp_dir/ftp.sym"
grep -Fq 'F13_HOST: EQU 0x0000B800' "$tmp_dir/ftp.sym"
# Resident below the load address, 16 KiB clear of every stack.
grep -Fq 'S10_COMMAND_BUFFER: EQU 0x00004000' "$tmp_dir/ftp.sym"
grep -Fq 'S10_RUNTIME_STACK_TOP: EQU 0x0000BFF0' "$tmp_dir/ftp.sym"

# DLSPEED reuses WGET's own W12_* state fields (STAGE12_LAYOUT, no
# STAGE13_LAYOUT): the two EXEs never coexist in memory.
grep -Fq 'W12_STATE_BASE: EQU 0x0000AD20' "$tmp_dir/dlspeed.sym"
grep -Fq 'S10_COMMAND_BUFFER: EQU 0x00004000' "$tmp_dir/dlspeed.sym"
grep -Fq 'S10_RUNTIME_STACK_TOP: EQU 0x0000BFF0' "$tmp_dir/dlspeed.sym"

echo "Stage 13 ASM: FTP/DLSPEED headers, WIN1 image limit, WIN2 page stack and two-channel layout passed (FTP $ftp_size bytes, DLSPEED $dlspeed_size bytes)"
