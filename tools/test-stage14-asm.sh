#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
dll="$repo_root/build/UNET509B.DLL"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-stage14.XXXXXX")"
if [ -n "${KEEP_STAGE14_TMP:-}" ]; then
  trap 'echo "Stage 14 temporary files: $tmp_dir"' EXIT
else
  trap 'rm -rf "$tmp_dir"' EXIT
fi

if [ ! -f "$dll" ]; then
  echo "Error: build/UNET509B.DLL is missing -- run tools/build.sh first" >&2
  exit 1
fi

# 1. Relocate the SHIPPED L1 image exactly the way libman13's `remake`
#    does (src/lib/libman13.asm): the header at offset 0 is 32 bytes, the
#    word at +4 is where the relocation bitmap starts (= end of the code
#    image), the word at +2 is the file size (= end of the bitmap); one
#    bitmap bit per code byte, MSB first; a set bit adds the high byte of
#    the load address to that code byte. This is an independent
#    re-implementation, not a call into sprinter-mkdll, so it also checks
#    that mkdll's bitmap and libman's loader agree on bit order and origin.
python3 - "$dll" "$tmp_dir" <<'PYEOF'
import struct
import sys

dll_path, out_dir = sys.argv[1], sys.argv[2]
with open(dll_path, "rb") as f:
    data = f.read()
if data[:2] != b"L1":
    sys.exit("UNET509B.DLL is not an L1 image")
file_size, = struct.unpack_from("<H", data, 2)
reloc_start, = struct.unpack_from("<H", data, 4)
header, image = data[:32], data[32:reloc_start]
bitmap = data[reloc_start:file_size]
if len(bitmap) * 8 < len(image):
    sys.exit("relocation bitmap is shorter than the code image")
with open(f"{out_dir}/image_0020.bin", "wb") as f:
    f.write(image)
for base in (0x4000, 0x8000, 0xC000):
    out = bytearray(image)
    delta = base >> 8
    for i in range(len(out)):
        if bitmap[i >> 3] & (0x80 >> (i & 7)):
            out[i] = (out[i] + delta) & 0xFF
    with open(f"{out_dir}/dll_{base:04X}.bin", "wb") as f:
        f.write(header + bytes(out))

# The cold overlay is appended past the L1 file as [LE16 length][blob]; it is
# assembled at ORG 0 and COLD.RUN maps it to window 0 and CALLs 0x0000.
blob_len, = struct.unpack_from("<H", data, file_size)
blob = data[file_size + 2:file_size + 2 + blob_len]
if len(blob) != blob_len:
    sys.exit("cold blob is truncated in UNET509B.DLL")
with open(f"{out_dir}/cold.bin", "wb") as f:
    f.write(blob)
PYEOF

# 2. Assemble the shim stand-alone at the three origins mkdll/libman produce
#    (0x0020 in the file, 0x4020/0x8020 in memory) by rewriting the one ORG
#    line the same way sprinter-mkdll does, and require byte identity with
#    (a) the shipped image and (b) the relocated copies. (a) proves the
#    stand-alone build is the shipped code; (b) proves the relocation bitmap
#    reproduces direct assembly in either window -- an absolute address
#    that mkdll's two-pass diff missed would show up here as a mismatch.
assemble_shim() {
  local org="$1"
  sed "s/^\([[:space:]]*ORG[[:space:]]*\)0x0000\([[:space:];]\)/\10x$org\2/" \
    "$repo_root/src/dll/unet509b.asm" > "$tmp_dir/shim_$org.asm"
  grep -Eq "^[[:space:]]*ORG[[:space:]]*0x$org" "$tmp_dir/shim_$org.asm"
  sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
    --sym="$tmp_dir/shim_$org.sym" --raw="$tmp_dir/shim_$org.bin" \
    "$tmp_dir/shim_$org.asm" >"$tmp_dir/shim_$org.log" 2>&1
  if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/shim_$org.log"; then
    cat "$tmp_dir/shim_$org.log" >&2
    exit 1
  fi
}
assemble_shim 0020
assemble_shim 4020
assemble_shim 8020
cmp "$tmp_dir/shim_0020.bin" "$tmp_dir/image_0020.bin"
tail -c +33 "$tmp_dir/dll_4000.bin" > "$tmp_dir/reloc_4020.bin"
tail -c +33 "$tmp_dir/dll_8000.bin" > "$tmp_dir/reloc_8020.bin"
cmp "$tmp_dir/shim_4020.bin" "$tmp_dir/reloc_4020.bin"
cmp "$tmp_dir/shim_8020.bin" "$tmp_dir/reloc_8020.bin"

# The in-image BSS canary follows DLL_BSS + DLL_BSS_SIZE; the vectors read
# it back through the same relocated image they call into.
bss_addr="$(awk '/^DLL_BSS:/ {print $3}' "$tmp_dir/shim_0020.sym")"
bss_size="$(awk '/^DLL_BSS_SIZE:/ {print $3}' "$tmp_dir/shim_0020.sym")"
canary_off=$(( bss_addr - 0x20 + bss_size ))

# Offsets the STATUS pend vector writes into: the per-channel state byte the
# shim keeps and the TCPX context field that holds a channel's undrained byte
# count. Taken from the build's own symbols so a BSS reshuffle cannot leave
# the vector poking at a stale address.
ch_state_off=$(( $(awk '/^UNET_CH_STATE:/ {print $3}' "$tmp_dir/shim_0020.sym") - 0x20 ))
ctx1_addr="$(awk '/^S11_CONTEXT1:/ {print $3}' "$tmp_dir/shim_0020.sym")"
pend1_addr="$(awk '/^S11_PENDING1:/ {print $3}' "$tmp_dir/shim_0020.sym")"
pend_field="$(awk '/^TCPX[.]CTX_PENDING_LEN:/ {print $3}' "$tmp_dir/shim_0020.sym")"
pend1_off=$(( ctx1_addr + pend_field - 0x20 ))
ctx1_off=$(( ctx1_addr - 0x20 ))
pend1_data_off=$(( pend1_addr - 0x20 ))
inited_off=$(( $(awk '/^UNET_INITED:/ {print $3}' "$tmp_dir/shim_0020.sym") - 0x20 ))
[ "$(od -An -tu1 -j "$canary_off" -N 1 "$tmp_dir/image_0020.bin" | tr -d ' ')" = 165 ]

# 3. Run the entry-point vectors under z88dk-ticks in each layout.
run_layout() {
  local name="$1" dll_base="$2" vec_base="$3" extra="${4:-}"
  local defines=(-DDLL_BASE="0x$dll_base" -DVEC_BASE="0x$vec_base" -DCANARY_OFF="$canary_off"
                 -DCH_STATE_OFF="$ch_state_off" -DPEND1_OFF="$pend1_off"
                 -DCTX1_OFF="$ctx1_off" -DPENDING1_DATA_OFF="$pend1_data_off"
                 -DINITED_OFF="$inited_off")
  [ -n "$extra" ] && defines+=("-D$extra")
  cp "$tmp_dir/dll_$dll_base.bin" "$tmp_dir/dll_image.bin"
  (
    cd "$tmp_dir"
    sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$tmp_dir" \
      "${defines[@]}" --sym="$tmp_dir/vec_$name.sym" \
      "$script_dir/stage14_vectors.asm" >"$tmp_dir/vec_$name.log" 2>&1
  )
  if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/vec_$name.log"; then
    cat "$tmp_dir/vec_$name.log" >&2
    exit 1
  fi
  local end_addr result complete
  end_addr="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/vec_$name.sym")"
  z88dk-ticks -l 0 -pc "$vec_base" -end "$end_addr" -counter 100000000 \
    -output "$tmp_dir/vec_$name.ram" "$tmp_dir/vectors.bin" >/dev/null
  result="$(od -An -tu1 -j 16128 -N 1 "$tmp_dir/vec_$name.ram" | tr -d ' ')"
  complete="$(od -An -tu1 -j 16129 -N 1 "$tmp_dir/vec_$name.ram" | tr -d ' ')"
  if [ "$complete" != 165 ] || [ "$result" != 0 ]; then
    echo "Error: Stage 14 ASM vector ($name) failed at case $result (complete=$complete)" >&2
    exit 1
  fi
}
run_layout win1 4000 8000
run_layout win2 8000 4000
run_layout win3 C000 4000 WIN3_REFUSAL

# 4. Run the cold-overlay vectors against both checksum policies at real ORG
#    zero.  The safe pass consumes the SHIPPED blob.  The fast pass assembles
#    the exact same cold source with its internal performance define; the
#    vectors require every slow-path guard to remain live and differ only on
#    an established in-order data segment with a deliberately bad TCP sum.
cp "$tmp_dir/cold.bin" "$tmp_dir/cold_safe.bin"
sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$repo_root/src/lib" \
  -DTCPX_UNCHECKED_DATA_RX --raw="$tmp_dir/cold_fast.bin" \
  "$repo_root/src/dll/unet509b_cold.asm" >"$tmp_dir/cold_fast.log" 2>&1
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/cold_fast.log"; then
  cat "$tmp_dir/cold_fast.log" >&2
  exit 1
fi
run_cold() {
  local name="$1" blob="$2" extra="${3:-}"
  local defines=(-DVEC_BASE=0x2000)
  [ -n "$extra" ] && defines+=("-D$extra")
  cp "$blob" "$tmp_dir/cold.bin"
  (
    cd "$tmp_dir"
    sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$tmp_dir" \
      "${defines[@]}" --sym="$tmp_dir/vec_cold_$name.sym" \
      "$script_dir/stage14_cold_vectors.asm" >"$tmp_dir/vec_cold_$name.log" 2>&1
  )
  if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/vec_cold_$name.log"; then
    cat "$tmp_dir/vec_cold_$name.log" >&2
    exit 1
  fi
  local cold_end cold_result cold_complete
  cold_end="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/vec_cold_$name.sym")"
  z88dk-ticks -l 0 -pc 0x2000 -end "$cold_end" -counter 100000000 \
    -output "$tmp_dir/vec_cold_$name.ram" "$tmp_dir/cold_vectors.bin" >/dev/null
  cold_result="$(od -An -tu1 -j 16128 -N 1 "$tmp_dir/vec_cold_$name.ram" | tr -d ' ')"
  cold_complete="$(od -An -tu1 -j 16129 -N 1 "$tmp_dir/vec_cold_$name.ram" | tr -d ' ')"
  if [ "$cold_complete" != 165 ] || [ "$cold_result" != 0 ]; then
    echo "Error: Stage 14 cold-overlay vector ($name) failed at case $cold_result (complete=$cold_complete)" >&2
    exit 1
  fi
}
run_cold safe "$tmp_dir/cold_safe.bin"
run_cold fast "$tmp_dir/cold_fast.bin" UNCHECKED_BUILD
# Deepest stack the vectors saw a cold call use, measured in the exact
# 0x3F80..0x3FFF reservation used by COLD.RUN (case 150-153). Its poisoned
# bottom byte is the boundary canary, so an underflow fails the vector.
cold_depth="$(od -An -tu2 -j 16132 -N 2 "$tmp_dir/vec_cold_safe.ram" | tr -d ' ')"
cp "$tmp_dir/cold_safe.bin" "$tmp_dir/cold.bin"

# 5. Run the passive-open vectors against the whole machine: the shipped blob
#    at its ORG, the shipped image relocated into WIN1, and a capture stub in
#    place of NETDRV.SEND_FRAME. TCPX_LISTEN is compiled into the DLL build
#    only, so without this run not one automated test executes a passive-open
#    instruction and a broken SYN|ACK is indistinguishable from silence on the
#    wire. Everything the vectors reach into is addressed through the build's
#    own symbols.
sym() {
  local value
  value="$(awk -v want="$1:" '$1 == want {print $3; exit}' "$tmp_dir/shim_0020.sym")"
  if [ -z "$value" ]; then
    echo "Error: symbol $1 is missing from the UNET509B.DLL build" >&2
    exit 1
  fi
  echo "$value"
}
listen_defines=(
  -DSYM_PROCESS_FRAME="$(sym TCPX.PROCESS_FRAME)"
  -DSYM_SEND_FRAME="$(sym NETDRV.SEND_FRAME)"
  -DSYM_SECONDS="$(sym S9APP.SECONDS)"
  -DSYM_COLD_READY="$(sym COLD.READY)"
  -DSYM_FILL_COLD_CTX="$(sym UNET.FILL_COLD_CTX)"
  -DSYM_LOCAL_IP="$(sym NET_LOCAL_IP)"
  -DSYM_STATION_MAC="$(sym NETDRV_STATION_MAC)"
  -DSYM_RX_BUF="$(sym STAGE9_RX_BUFFER)"
  -DSYM_FRAME_LEN="$(sym S11_FRAME_LENGTH)"
  -DSYM_CTX0="$(sym S11_CONTEXT0)"
  -DSYM_INITED="$(sym UNET_INITED)"
  -DSYM_RX_PENDING="$(sym NETDRV.RX_PENDING)"
  -DSYM_READ_FRAME="$(sym NETDRV.READ_FRAME)"
  -DSYM_RX_BEGIN="$(sym EL3IO.RX_BEGIN)"
  -DSYM_RX_PAYLOAD="$(sym EL3IO.RX_PAYLOAD)"
  -DSYM_CH_STATE="$(sym UNET_CH_STATE)"
  -DSYM_LISTEN_ACCEPTED="$(sym UNET_LISTEN_ACCEPTED)"
  -DSYM_READ_WALL="$(sym NETTIME.READ_WALL)"
  -DSYM_CHECK_CANCEL="$(sym TCPX.CHECK_CANCEL)"
  -DCTX_STATE="$(sym TCPX.CTX_STATE)"
  -DCTX_LOCAL_PORT="$(sym TCPX.CTX_LOCAL_PORT)"
  -DCTX_REMOTE_IP="$(sym TCPX.CTX_REMOTE_IP)"
  -DCTX_REMOTE_MAC="$(sym TCPX.CTX_REMOTE_MAC)"
  -DCTX_REMOTE_PORT="$(sym TCPX.CTX_REMOTE_PORT)"
  -DCTX_RCV_NXT="$(sym TCPX.CTX_RCV_NXT)"
  -DCTX_EVENT="$(sym TCPX.CTX_EVENT)"
  -DEVENT_SYN_ACK="$(sym TCPX.EVENT_SYN_ACK)"
)
cp "$tmp_dir/dll_4000.bin" "$tmp_dir/dll_image.bin"
(
  cd "$tmp_dir"
  sjasmplus --nologo --fullpath -I "$repo_root/src/include" -I "$tmp_dir" \
    "${listen_defines[@]}" --sym="$tmp_dir/vec_listen.sym" \
    "$script_dir/stage14_listen_vectors.asm" >"$tmp_dir/vec_listen.log" 2>&1
)
if grep -Eq 'Errors: [1-9]|error:' "$tmp_dir/vec_listen.log"; then
  cat "$tmp_dir/vec_listen.log" >&2
  exit 1
fi
listen_end="$(awk '/^TEST_DONE:/ {sub(/^0x0*/, "", $3); print $3}' "$tmp_dir/vec_listen.sym")"
# These vectors are the first to drive TCPX's polling wait loops, and
# z88dk-ticks stops honouring -counter as soon as -end is given: a vector that
# never reaches TEST_DONE would hang the gate for good instead of failing it.
# The whole run is well under a second, so a wall-clock bound costs nothing.
z88dk-ticks -l 0 -pc 0x8000 -end "$listen_end" -counter 100000000 \
  -output "$tmp_dir/vec_listen.ram" "$tmp_dir/listen_vectors.bin" >/dev/null &
listen_pid=$!
for _ in $(seq 1 60); do
  kill -0 "$listen_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$listen_pid" 2>/dev/null; then
  kill -9 "$listen_pid" 2>/dev/null || true
  echo "Error: Stage 14 passive-open vector never reached TEST_DONE (runaway loop)" >&2
  exit 1
fi
wait "$listen_pid" || true
listen_result="$(od -An -tu1 -j 16128 -N 1 "$tmp_dir/vec_listen.ram" | tr -d ' ')"
listen_complete="$(od -An -tu1 -j 16129 -N 1 "$tmp_dir/vec_listen.ram" | tr -d ' ')"
if [ "$listen_complete" != 165 ] || [ "$listen_result" != 0 ]; then
  echo "Error: Stage 14 passive-open vector failed at case $listen_result (complete=$listen_complete)" >&2
  exit 1
fi

image_size="$(wc -c < "$tmp_dir/image_0020.bin" | tr -d ' ')"
cold_size="$(wc -c < "$tmp_dir/cold.bin" | tr -d ' ')"
echo "Stage 14 ASM: shipped image == stand-alone build, libman relocation to WIN1/WIN2 == direct assembly, 41 entry-point vectors in WIN1 and WIN2, window-3 refusal, safe/fast cold-overlay suites, 18 passive-open vectors passed (image $image_size bytes, cold $cold_size bytes, deepest cold stack $cold_depth of 128; boundary canary intact)"
