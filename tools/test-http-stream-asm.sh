#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-http-stream.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

sjasmplus --nologo --fullpath --cleanonerror \
  -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  --sym="$tmp_dir/http.sym" --raw="$tmp_dir/http.bin" \
  "$script_dir/http_stream_vectors.asm" >"$tmp_dir/assembly.log"
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/assembly.log"; then
  cat "$tmp_dir/assembly.log" >&2
  exit 1
fi

end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/http.sym")"
z88dk-ticks -l 16384 -pc 4000 -end "$end_addr" -counter 10000000 \
  -output "$tmp_dir/http.ram" "$tmp_dir/http.bin" >/dev/null
result="$(od -An -tu1 -j 49152 -N1 "$tmp_dir/http.ram" | tr -d ' ')"
complete="$(od -An -tu1 -j 49153 -N1 "$tmp_dir/http.ram" | tr -d ' ')"
if [ "$complete" != 165 ] || [ "$result" != 0 ]; then
  echo "Error: shared HTTP parser vector failed at case $result (complete=$complete)" >&2
  exit 1
fi

echo "HTTP stream ASM: split headers, exact/overflow length, keep-alive, close-delimited, strict status and encoding vectors passed"
