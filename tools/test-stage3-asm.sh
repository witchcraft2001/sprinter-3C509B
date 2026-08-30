#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage3.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/stage3.sym" --raw="$tmp_dir/stage3.bin" \
  "$script_dir/stage3_vectors.asm" >/dev/null

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage3.sym")"
if [ -z "$end_addr" ]; then
  echo "Error: TEST_DONE is missing from Stage 3 symbols" >&2
  exit 1
fi

z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" \
  -output "$tmp_dir/stage3.ram" "$tmp_dir/stage3.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage3.ram" | tr -d ' ')"
if [ "$result" != 0 ]; then
  echo "Error: Stage 3 ASM vector failed at case $result" >&2
  exit 1
fi

echo "Stage 3 ASM vectors: LFSR[255], 31 bases, EEPROM/MAC/checksums, and CLI bounds passed"
