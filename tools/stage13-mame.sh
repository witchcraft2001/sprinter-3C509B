#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage13-mame"
fixture_dir="$stage_dir/fixtures"
image="$stage_dir/stage13-ftp.img"
responder_if="${STAGE13_RESPONDER_INTERFACE:-feth1}"
mame_if="${STAGE13_MAME_INTERFACE:-feth0}"
evidence_dir="${STAGE13_EVIDENCE_DIR:-$repo_root/evidence/stage13}"
profile="${STAGE13_PROFILE:-clean}"

case "${1:-}" in
  prepare)
    mkdir -p "$stage_dir" "$fixture_dir"
    "$script_dir/image.sh"
    python3 "$script_dir/host/stage13_responder.py" --prepare-fixtures "$fixture_dir"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE13.CFG" ::NET.CFG
    echo "Prepared $image"
    ;;
  responder)
    mkdir -p "$evidence_dir"
    exec python3 "$script_dir/host/stage13_responder.py" --interface "$responder_if" \
      --pcap "$evidence_dir/stage13.pcap" --log "$evidence_dir/stage13.log" \
      --profile "$profile"
    ;;
  mame)
    [ -f "$image" ] || { echo "Run tools/stage13-mame.sh prepare first" >&2; exit 2; }
    mkdir -p "$stage_dir/cfg"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg" exec "$script_dir/3com.sh"
    ;;
  verify)
    mkdir -p "$stage_dir/extracted" "$evidence_dir"
    for name in SMALL.BIN LARGE.BIN; do
      mcopy -i "$image" -o "::$name" "$stage_dir/extracted/$name"
      cmp "$fixture_dir/$name" "$stage_dir/extracted/$name"
    done
    mcopy -i "$image" -o ::FTP.EXE "$stage_dir/extracted/FTP.EXE"
    cmp "$repo_root/build/FTP.EXE" "$stage_dir/extracted/FTP.EXE"
    mcopy -i "$image" -o ::DLSPEED.EXE "$stage_dir/extracted/DLSPEED.EXE"
    cmp "$repo_root/build/DLSPEED.EXE" "$stage_dir/extracted/DLSPEED.EXE"
    python3 "$script_dir/host/stage13_responder.py" \
      --check-pcap "$evidence_dir/stage13.pcap"
    hash_tool=(shasum -a 256)
    if command -v sha256sum >/dev/null 2>&1; then hash_tool=(sha256sum); fi
    {
      echo "Stage 13 evidence summary"
      echo "Verification: PASS (fixtures, extracted IMG files, FTP/DLSPEED copies and pcap contract)"
      "${hash_tool[@]}" "$image" "$repo_root/build/FTP.EXE" "$repo_root/build/DLSPEED.EXE" \
        "$fixture_dir"/*.BIN "$stage_dir/extracted"/*.BIN \
        "$evidence_dir/stage13.log" "$evidence_dir/stage13.pcap"
    } > "$evidence_dir/SUMMARY.txt"
    echo "VERIFY OK; hashes recorded in $evidence_dir/SUMMARY.txt"
    ;;
  pcap-check)
    exec python3 "$script_dir/host/stage13_responder.py" \
      --check-pcap "${2:-$evidence_dir/stage13.pcap}"
    ;;
  *)
    echo "usage: tools/stage13-mame.sh {prepare|responder|mame|verify|pcap-check [PCAP]}" >&2
    exit 2
    ;;
esac
