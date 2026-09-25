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
# image is code and rodata; the runtime data area bounds it -- crossing it
# overwrites buffers silently. FTP's data area starts 2 KiB above PAGE_BASE
# (memory.inc's S13_IMAGE_LIMIT, 8800h), which pays for its session receive
# path. DLDIRECT's starts 1 KiB above it (S12_IMAGE_LIMIT, 8400h): it builds TCP
# and DNS frames in the receive buffer, which pays for its out-of-order queue.
ftp_size="$(wc -c < "$tmp_dir/FTP.EXE" | tr -d ' ')"
[ "$ftp_size" -le $((0x8800 - 0x4080)) ]
dldirect_size="$(wc -c < "$tmp_dir/DLDIRECT.EXE" | tr -d ' ')"
[ "$dldirect_size" -le $((0x8400 - 0x4080)) ]
grep -Fq 'S12_IMAGE_LIMIT: EQU 0x00008400' "$tmp_dir/dldirect.sym"
grep -Fq 'STAGE9_TX_BUFFER: EQU 0x00008400' "$tmp_dir/dldirect.sym"
grep -Fq 'TCPX_TX_BUFFER: EQU 0x00008600' "$tmp_dir/dldirect.sym"
grep -Fq 'DNSX_TX_BUFFER: EQU 0x00008600' "$tmp_dir/dldirect.sym"
grep -Fq 'OOO_TABLE: EQU 0x0000AB6E' "$tmp_dir/dldirect.sym"
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
# The two durable queues are deliberately different sizes (TCPX_SPLIT_PENDING):
# region 0 is the control channel at one 1460-byte segment, region 1 the data
# channel at two. The block starts where the 4 KiB disk buffer ends and is
# still packed flush against RUNTIME_BASE, so these three addresses together
# pin the whole asymmetric layout: a regression that sized both queues alike
# would move every one of them.
grep -Fq 'S11_PENDING0: EQU 0x00009C00' "$tmp_dir/ftp.sym"
grep -Fq 'S11_PENDING1: EQU 0x0000A1B4' "$tmp_dir/ftp.sym"
grep -Fq 'S11_CONTEXT1: EQU 0x0000AD44' "$tmp_dir/ftp.sym"
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
