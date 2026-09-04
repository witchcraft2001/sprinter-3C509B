#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage12-mame"
fixture_dir="$stage_dir/fixtures"
image="$stage_dir/stage12-wget.img"
responder_if="${STAGE12_RESPONDER_INTERFACE:-feth1}"
mame_if="${STAGE12_MAME_INTERFACE:-feth0}"
evidence_dir="${STAGE12_EVIDENCE_DIR:-$repo_root/evidence/stage12}"

case "${1:-}" in
  prepare)
    mkdir -p "$stage_dir" "$fixture_dir"
    "$script_dir/image.sh"
    python3 "$script_dir/host/stage12_responder.py" --prepare-fixtures "$fixture_dir"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE12.CFG" ::NET.CFG
    dd if="$fixture_dir/RANGE.BIN" of="$stage_dir/RANGE.BIN" bs=65536 count=1 status=none
    mcopy -i "$image" -o "$stage_dir/RANGE.BIN" ::RANGE.BIN
    echo "Prepared $image; RANGE.BIN contains the 65536-byte resume prefix"
    ;;
  responder)
    mkdir -p "$evidence_dir"
    exec python3 "$script_dir/host/stage12_responder.py" --interface "$responder_if" \
      --pcap "$evidence_dir/stage12.pcap" --log "$evidence_dir/stage12.log"
    ;;
  mame)
    [ -f "$image" ] || { echo "Run tools/stage12-mame.sh prepare first" >&2; exit 2; }
    mkdir -p "$stage_dir/cfg"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg" exec "$script_dir/3com.sh"
    ;;
  verify)
    mkdir -p "$stage_dir/extracted" "$evidence_dir"
    for name in ZERO.BIN SMALL.BIN LARGE.BIN RANGE.BIN CLOSE.BIN; do
      mcopy -i "$image" -o "::$name" "$stage_dir/extracted/$name"
      cmp "$fixture_dir/$name" "$stage_dir/extracted/$name"
    done
    mcopy -i "$image" -o ::WGET.EXE "$stage_dir/extracted/WGET.EXE"
    cmp "$repo_root/build/WGET.EXE" "$stage_dir/extracted/WGET.EXE"
    python3 "$script_dir/host/stage12_responder.py" \
      --check-pcap "$evidence_dir/stage12.pcap"
    hash_tool=(shasum -a 256)
    if command -v sha256sum >/dev/null 2>&1; then hash_tool=(sha256sum); fi
    {
      echo "Stage 12 evidence summary"
      echo "Verification: PASS (fixture, extracted IMG files, WGET copy and pcap contract)"
      "${hash_tool[@]}" "$image" "$repo_root/build/WGET.EXE" \
        "$fixture_dir"/*.BIN "$stage_dir/extracted"/*.BIN \
        "$evidence_dir/stage12.log" "$evidence_dir/stage12.pcap"
    } > "$evidence_dir/SUMMARY.txt"
    echo "VERIFY OK; hashes recorded in $evidence_dir/SUMMARY.txt"
    ;;
  pcap-check)
    exec python3 "$script_dir/host/stage12_responder.py" \
      --check-pcap "${2:-$evidence_dir/stage12.pcap}"
    ;;
  *)
    echo "usage: tools/stage12-mame.sh {prepare|responder|mame|verify|pcap-check [PCAP]}" >&2
    exit 2
    ;;
esac
