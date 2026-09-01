#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
mkdir -p "$repo_root/build"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage9.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
sjasmplus --nologo --fullpath --cleanonerror \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/stage9.sym" --raw="$tmp_dir/stage9.bin" \
  "$script_dir/stage9_vectors.asm" >"$tmp_dir/assembly.log"
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/assembly.log"; then
  cat "$tmp_dir/assembly.log" >&2
  exit 1
fi
end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage9.sym")"
z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 50000000 \
  -output "$tmp_dir/stage9.ram" "$tmp_dir/stage9.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage9.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/stage9.ram" | tr -d ' ')"
if [ "$complete" != 165 ] || [ "$result" != 0 ]; then
  echo "Error: Stage 9 ASM vector failed at case $result (complete=$complete)" >&2
  exit 1
fi
echo "Stage 9 ASM: UDP checksum/bounds and TFTP framing/options passed"
