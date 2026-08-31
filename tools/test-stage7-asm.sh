#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage7.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath --cleanonerror \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/stage7.sym" --raw="$tmp_dir/stage7.bin" \
  "$script_dir/stage7_vectors.asm" >"$tmp_dir/assembly.log"
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/assembly.log"; then
  cat "$tmp_dir/assembly.log" >&2
  exit 1
fi

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/stage7.sym")"
z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 30000000 \
  -output "$tmp_dir/stage7.ram" "$tmp_dir/stage7.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/stage7.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/stage7.ram" | tr -d ' ')"
if [ "$complete" != 165 ] || [ "$result" != 0 ]; then
  echo "Error: Stage 7 ASM vector failed at case $result (complete=$complete)" >&2
  exit 1
fi
echo "Stage 7 ASM: checksum, ARP framing/routing/cache and DHCP/config vectors passed"

for window in 0 1 2; do
  sjasmplus --nologo --fullpath --cleanonerror -DNETDRV_DLL_WINDOW="$window" \
    -I "$repo_root/src/include" -I "$repo_root/src/lib" \
    --sym="$tmp_dir/netdrv-$window.sym" --raw="$tmp_dir/netdrv-$window.bin" \
    "$script_dir/netdrv_vectors.asm" >"$tmp_dir/netdrv-$window.log"
  if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/netdrv-$window.log"; then
    cat "$tmp_dir/netdrv-$window.log" >&2
    exit 1
  fi
  netdrv_end="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/netdrv-$window.sym")"
  z88dk-ticks -l 16384 -pc 4000 -end "$netdrv_end" -counter 3000000 \
    -output "$tmp_dir/netdrv-$window.ram" "$tmp_dir/netdrv-$window.bin" >/dev/null
  result="$(od -An -tu1 -j 49152 -N 1 "$tmp_dir/netdrv-$window.ram" | tr -d ' ')"
  complete="$(od -An -tu1 -j 49153 -N 1 "$tmp_dir/netdrv-$window.ram" | tr -d ' ')"
  if [ "$complete" != 165 ] || [ "$result" != 0 ]; then
    echo "Error: NETDRV window $window vector failed at case $result (complete=$complete)" >&2
    exit 1
  fi
done
echo "NETDRV ASM: ABI preservation and NONE/WIN1/WIN2 buffer boundaries passed"
