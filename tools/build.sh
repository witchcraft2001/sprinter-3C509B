#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="${BUILD_DIR:-$repo_root/build}"

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is required but was not found in PATH" >&2
  exit 1
fi

if ! command -v sprinter-mkdll >/dev/null 2>&1; then
  echo "Error: sprinter-mkdll is required but was not found in PATH" >&2
  exit 1
fi

mkdir -p "$build_dir"

build_app()
{
  local source_name="$1"
  local artifact_name="$2"
  local assembly_log
  assembly_log="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-build.XXXXXX")"
  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$build_dir/$artifact_name.lst" \
    --raw="$build_dir/$artifact_name.EXE" \
    "$repo_root/src/apps/$source_name.asm" >"$assembly_log"
  cat "$assembly_log"
  if grep -Eq 'Errors: [1-9]|error:' "$assembly_log"; then
    rm -f "$assembly_log"
    return 1
  fi
  rm -f "$assembly_log"
  echo "Built ${build_dir#$repo_root/}/$artifact_name.EXE"
}

# build_dll: assemble UNET509B.DLL as a libman 1.3 / L1 relocatable image
# (two sjasmplus passes + relocation bitmap, done by sprinter-mkdll itself),
# then append the WIN0-cold protocol-codec blob (src/dll/unet509b_cold.asm,
# runs via src/lib/win0cold.asm's MMU-window-0 overlay -- see that file's
# header) as [2-byte LE length][blob bytes] right after the L1 image.
# libman's loader only ever reads the L1 header's own file_size bytes, so
# this trailing data is inert to every OTHER consumer of the DLL; verified
# against `sprinter-mkdll verify`/`inspect`, which report it as ordinary
# trailing_size and still pass. A failed cold-blob assembly is a hard
# error, not a silent skip: COLD.INIT's own best-effort fallback (see its
# header) is what makes a MISSING blob safe at runtime, but a build that
# meant to ship one and silently didn't would ship a DLL that always
# reports NETINIT NERR_HW/cold=<stage> for anything that needs it.
build_dll()
{
  local full_version major_minor cold_bin cold_size
  local cold_defines=()
  full_version="$(sed -n 's/.*PACKAGE_VERSION[^"]*"\([^"]*\)".*/\1/p' \
    "$repo_root/src/include/version.inc")"
  major_minor="$(printf '%s' "$full_version" | cut -d. -f1,2)"
  sprinter-mkdll build "$repo_root/src/dll/unet509b.asm" \
    --format l1 --target 1.3 --assembler sjasmplus \
    -I "$repo_root/src/include" -I "$repo_root/src/lib" \
    --name "UNET509B v$full_version" --version "$major_minor" --no-compress \
    -o "$build_dir/UNET509B.DLL"
  sprinter-mkdll verify "$build_dir/UNET509B.DLL" --target 1.3

  if [ "${TCPX_UNCHECKED_DATA_RX:-0}" = 1 ]; then
    cold_defines+=(-DTCPX_UNCHECKED_DATA_RX)
  fi
  cold_bin="$build_dir/unet509b_cold.bin"
  sjasmplus --nologo --fullpath -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" "${cold_defines[@]}" "--raw=$cold_bin" \
    "$repo_root/src/dll/unet509b_cold.asm"
  python3 - "$build_dir/UNET509B.DLL" "$cold_bin" <<'PYEOF'
import struct, sys
out_path, cold_path = sys.argv[1], sys.argv[2]
with open(cold_path, "rb") as f:
    cold = f.read()
with open(out_path, "ab") as f:
    f.write(struct.pack("<H", len(cold)))
    f.write(cold)
PYEOF
  sprinter-mkdll verify "$build_dir/UNET509B.DLL" --target 1.3
  cold_size="$(wc -c < "$cold_bin" | tr -d ' ')"
  rm -f "$cold_bin"
  echo "Built ${build_dir#$repo_root/}/UNET509B.DLL (cold blob: $cold_size bytes)"
}

build_dll

# TELNET.EXE is a Fido-style monolithic preloader container.  DSS loads only
# the small loader; it streams WIN0, WIN1 and the modem overlay into freshly
# allocated pages from the inherited EXE handle. No companion is shipped.
build_telnet()
{
  local win0_path hot_path modem_path loader_path win0_size hot_size modem_size loader_size
  win0_path="$build_dir/TELNET.WIN0"
  hot_path="$build_dir/TELNET.HOT"
  modem_path="$build_dir/TELNET.MODEM"
  loader_path="$build_dir/TELNET.LOADER"

  # Remove outputs from the former companion-file layout.  They are generated
  # files only; retaining them after a rebuild would falsely suggest TELNET
  # still needs a second disk file.
  rm -f "$build_dir/TELMOD.BIN" "$build_dir/TELMOD.lst"

  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    -DTELNET_MONOBLOCK_HOT \
    --lst="$build_dir/TELNET.lst" \
    --raw="$hot_path" \
    "$repo_root/src/apps/telnet.asm"
  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$build_dir/TELWIN0.lst" \
    --raw="$win0_path" \
    "$repo_root/src/apps/telnet_win0.asm"
  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$build_dir/TELMODEM.lst" \
    --raw="$modem_path" \
    "$repo_root/src/apps/telmodem.asm"
  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$build_dir/TELNETL.lst" \
    --raw="$loader_path" \
    "$repo_root/src/apps/telnet_loader.asm"
  python3 "$repo_root/tools/pack_telnet.py" "$build_dir/TELNET.EXE" \
    "$loader_path" "$win0_path" "$hot_path" "$modem_path"
  win0_size="$(wc -c < "$win0_path" | tr -d ' ')"
  hot_size="$(wc -c < "$hot_path" | tr -d ' ')"
  modem_size="$(wc -c < "$modem_path" | tr -d ' ')"
  loader_size="$(wc -c < "$loader_path" | tr -d ' ')"
  rm -f "$win0_path" "$hot_path" "$modem_path" "$loader_path"
  echo "Built ${build_dir#$repo_root/}/TELNET.EXE (loader: $loader_size, win0: $win0_size, win1: $hot_size, cold: $modem_size bytes)"
}

build_telnet
build_app hello HELLO
build_app el3info EL3INFO
build_app el3eep EL3EEP
build_app el3reg EL3REG
build_app el3lb EL3LB
build_app el3tx EL3TX
build_app el3rx EL3RX
build_app isaprobe ISAPROBE
build_app netcfg NETCFG
build_app ifup IFUP
build_app arp ARP
build_app ping PING
build_app pingalt PINGALT
build_app udptest UDPTEST
build_app tftp TFTP
build_app nslookup NSLOOKUP
build_app ntp NTP
build_app tcptest TCPTEST
build_app wget WGET
build_app ftp FTP
build_app dlspeed DLSPEED
build_app dldirect DLDIRECT
build_app netprof NETPROF
build_app unettest UNETTEST
