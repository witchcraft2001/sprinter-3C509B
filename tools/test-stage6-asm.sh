#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage6.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath --cleanonerror \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/stage6.sym" --raw="$tmp_dir/stage6.bin" \
  "$script_dir/stage6_vectors.asm" >"$tmp_dir/assembly.log"
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/assembly.log"; then
  cat "$tmp_dir/assembly.log" >&2
  exit 1
fi

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage6.sym")"
if [ -z "$end_addr" ]; then
  echo "Error: TEST_DONE is missing from Stage 6 symbols" >&2
  exit 1
fi
z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 20000000 \
  -output "$tmp_dir/stage6.ram" "$tmp_dir/stage6.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage6.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/stage6.ram" | tr -d ' ')"
if [ "$complete" != 165 ]; then
  echo "Error: Stage 6 ASM vector did not reach TEST_DONE" >&2
  exit 1
fi
if [ "$result" != 0 ]; then
  echo "Error: Stage 6 ASM vector failed at case $result" >&2
  exit 1
fi
echo "Stage 6 ASM: CRC32, DSS exit mapping and EL3TX/EL3RX CLI defaults/boundaries passed"
