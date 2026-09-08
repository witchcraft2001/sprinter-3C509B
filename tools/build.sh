#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is required but was not found in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

build_app()
{
  local source_name="$1"
  local artifact_name="$2"
  local assembly_log
  assembly_log="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-build.XXXXXX")"
  sjasmplus --nologo --fullpath --cleanonerror \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$repo_root/build/$artifact_name.lst" \
    --raw="$repo_root/build/$artifact_name.EXE" \
    "$repo_root/src/apps/$source_name.asm" >"$assembly_log"
  cat "$assembly_log"
  if grep -Eq 'Errors: [1-9]|error:' "$assembly_log"; then
    rm -f "$assembly_log"
    return 1
  fi
  rm -f "$assembly_log"
  echo "Built build/$artifact_name.EXE"
}

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
