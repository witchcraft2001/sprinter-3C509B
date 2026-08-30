#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage4.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/stage4.sym" --raw="$tmp_dir/stage4.bin" \
  "$script_dir/stage4_vectors.asm" >/dev/null

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage4.sym")"
if [ -z "$end_addr" ]; then
  echo "Error: TEST_DONE is missing from Stage 4 symbols" >&2
  exit 1
fi

z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 20000000 \
  -output "$tmp_dir/stage4.ram" "$tmp_dir/stage4.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage4.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/stage4.ram" | tr -d ' ')"
if [ "$complete" != 165 ]; then
  echo "Error: Stage 4 ASM vector did not reach TEST_DONE" >&2
  exit 1
fi
if [ "$result" != 0 ]; then
  echo "Error: Stage 4 ASM vector failed at case $result" >&2
  exit 1
fi

echo "Stage 4 ASM mock: ISA8 order, ABI, commands/windows, CIP/recovery, INIT/DONE x100, snapshot v1/60 and CLI bounds passed"
