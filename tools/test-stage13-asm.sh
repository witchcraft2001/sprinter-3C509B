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
sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/dldirect.sym" --raw="$tmp_dir/DLDIRECT.EXE" \
  "$repo_root/src/apps/dldirect.asm" >"$tmp_dir/dldirect-assembly.log"

# Both load at 4080h and, in the standard layout, own WIN1+WIN2 outright. The
# image is code and rodata; PAGE_BASE (8000h) is where the runtime data area
# begins, so that is what bounds it -- crossing it overwrites buffers silently.
ftp_size="$(wc -c < "$tmp_dir/FTP.EXE" | tr -d ' ')"
[ "$ftp_size" -le $((0x8000 - 0x4080)) ]
dldirect_size="$(wc -c < "$tmp_dir/DLDIRECT.EXE" | tr -d ' ')"
[ "$dldirect_size" -le $((0x8000 - 0x4080)) ]
dlspeed_size="$(wc -c < "$tmp_dir/DLSPEED.EXE" | tr -d ' ')"
[ "$dlspeed_size" -le $((0x9EF0 - 0x8080)) ]

for exe in FTP DLDIRECT; do
  [ "$(od -An -tx1 -N4 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "45584501" ]
  [ "$(od -An -tu2 -j16 -N2 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "16640" ]
  # Header stack: the top of WIN2, a whole window clear of the image.
  [ "$(od -An -tu2 -j20 -N2 "$tmp_dir/$exe.EXE" | tr -d ' \n')" = "49136" ]
done

[ "$(od -An -tx1 -N4 "$tmp_dir/DLSPEED.EXE" | tr -d ' \n')" = "45584501" ]
[ "$(od -An -tu2 -j16 -N2 "$tmp_dir/DLSPEED.EXE" | tr -d ' \n')" = "33024" ]
[ "$(od -An -tu2 -j20 -N2 "$tmp_dir/DLSPEED.EXE" | tr -d ' \n')" = "40944" ]
if tail -c +129 "$tmp_dir/DLSPEED.EXE" | perl -0777 -ne 'exit(/\x00{128}/ ? 0 : 1)'; then
  echo "DLSPEED.EXE contains zero-filled runtime BSS" >&2
  exit 1
fi

# FTP: two real TCP contexts (STAGE13_LAYOUT), not WGET's single-channel fold.
grep -Fq 'S11_CONTEXT1: EQU 0x0000AD18' "$tmp_dir/ftp.sym"
grep -Fq 'F13_HOST: EQU 0x0000B800' "$tmp_dir/ftp.sym"
# Resident below the load address, 16 KiB clear of every stack.
grep -Fq 'S10_COMMAND_BUFFER: EQU 0x00004000' "$tmp_dir/ftp.sym"
grep -Fq 'S10_RUNTIME_STACK_TOP: EQU 0x0000BFF0' "$tmp_dir/ftp.sym"

# DLDIRECT reuses WGET's W12_* state fields; DLSPEED is the independent WIN2
# libman client with a fixed 6-KiB buffer and caller-owned libman table.
grep -Fq 'W12_STATE_BASE: EQU 0x0000AD20' "$tmp_dir/dldirect.sym"
grep -Fq 'S10_COMMAND_BUFFER: EQU 0x00004000' "$tmp_dir/dldirect.sym"
grep -Fq 'S10_RUNTIME_STACK_TOP: EQU 0x0000BFF0' "$tmp_dir/dldirect.sym"
grep -Fq 'RX_BUFFER: EQU 0x0000A000' "$tmp_dir/dlspeed.sym"
grep -Fq 'LIBMAN_TABLE_BASE: EQU 0x0000BE00' "$tmp_dir/dlspeed.sym"
grep -Fq 'STACK_BOTTOM: EQU 0x00009EF0' "$tmp_dir/dlspeed.sym"
grep -Fq 'STACK_TOP: EQU 0x00009FF0' "$tmp_dir/dlspeed.sym"

echo "Stage 13 ASM: FTP/DLDIRECT native layout and DLSPEED DLL layout passed (FTP $ftp_size, DLDIRECT $dldirect_size, DLSPEED $dlspeed_size bytes)"
