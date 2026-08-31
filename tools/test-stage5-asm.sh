#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage5.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

asm_log="$tmp_dir/assembly.log"
sjasmplus --nologo --fullpath --cleanonerror -I "$repo_root/src/include" -I "$repo_root/src/lib" --sym="$tmp_dir/stage5.sym" --raw="$tmp_dir/stage5.bin" "$script_dir/stage5_vectors.asm" >"$asm_log"
if grep -Eq 'Errors: [1-9]|error:' "$asm_log"; then
  cat "$asm_log" >&2
  exit 1
fi

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage5.sym")"
if [ -z "$end_addr" ]; then
  echo "Error: TEST_DONE is missing from Stage 5 symbols" >&2
  exit 1
fi

z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 250000000 -output "$tmp_dir/stage5.ram" "$tmp_dir/stage5.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage5.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/stage5.ram" | tr -d ' ')"
if [ "$complete" != 165 ]; then
  echo "Error: Stage 5 ASM vector did not reach TEST_DONE" >&2
  exit 1
fi
if [ "$result" != 0 ]; then
  echo "Error: Stage 5 ASM vector failed at case $result" >&2
  exit 1
fi

echo "Stage 5 ASM mock: FIFO layout/timeouts, TX recovery gating, RX consume/distinct queues, loopback verify, counters, ABI and CLI passed"
