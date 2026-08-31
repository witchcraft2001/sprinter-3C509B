#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-mame-network.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

for tuple in '0 feth0 0' '1 feth1 1'; do
  read -r slot interface index <<< "$tuple"
  cfg="$tmp_dir/cfg-$slot"
  MAME_BIN="$script_dir/test-fixtures/fake-mame.sh" \
  MAME_RELEASE_DIR="$repo_root" \
  SPRINTER_3C509B_IMG="$repo_root/LICENSE" \
  MAME_CFG_DIR="$cfg" \
  MAME_3C509B_SLOT="$slot" \
  MAME_NETWORK_INTERFACE="$interface" \
    "$script_dir/3com.sh"
  grep -Fq "<device tag=\":isa$slot:3c509b\" interface=\"$index\" />" \
    "$cfg/sprinter.cfg"
done

cfg="$tmp_dir/cfg-spaces"
MAME_BIN="$script_dir/test-fixtures/fake-mame.sh" \
MAME_RELEASE_DIR="$repo_root" \
SPRINTER_3C509B_IMG="$repo_root/LICENSE" \
MAME_CFG_DIR="$cfg" \
MAME_3C509B_SLOT=1 \
MAME_NETWORK_INTERFACE='bridge with spaces' \
  "$script_dir/3com.sh"
grep -Fq '<device tag=":isa1:3c509b" interface="2" />' "$cfg/sprinter.cfg"

if MAME_BIN="$script_dir/test-fixtures/fake-mame.sh" \
  MAME_RELEASE_DIR="$repo_root" SPRINTER_3C509B_IMG="$repo_root/LICENSE" \
  MAME_CFG_DIR="$tmp_dir/bad" MAME_NETWORK_INTERFACE=missing0 \
  "$script_dir/3com.sh" >/dev/null 2>&1; then
  echo "Error: launcher accepted an interface absent from mame -listnetwork" >&2
  exit 1
fi

echo "MAME launcher: named interface validation and slot-specific pcap cfg passed"
