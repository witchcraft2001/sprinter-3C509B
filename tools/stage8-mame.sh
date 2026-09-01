#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage8-mame"
image="$stage_dir/stage8-static.img"
scenario="${2:-echo}"
responder_if="${STAGE8_RESPONDER_INTERFACE:-feth1}"
mame_if="${STAGE8_MAME_INTERFACE:-feth0}"
evidence_dir="${STAGE8_EVIDENCE_DIR:-$repo_root/evidence/stage8}"

case "${1:-}" in
  prepare)
    "$script_dir/image.sh"
    mkdir -p "$stage_dir"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE8.CFG" ::NET.CFG
    echo "Prepared $image with static 192.168.7.20/24 configuration"
    ;;
  responder)
    case "$scenario" in echo|noise|unreachable|drop|delay) ;; *) echo "unknown scenario: $scenario" >&2; exit 2;; esac
    mkdir -p "$evidence_dir"
    exec python3 "$script_dir/host/stage8_responder.py" "$scenario" \
      --interface "$responder_if" --pcap "$evidence_dir/$scenario.pcap"
    ;;
  mame)
    case "$scenario" in echo|noise|unreachable|drop|delay) ;; *) echo "unknown scenario: $scenario" >&2; exit 2;; esac
    if [ ! -f "$image" ]; then
      echo "Run tools/stage8-mame.sh prepare first" >&2
      exit 2
    fi
    mkdir -p "$stage_dir/cfg-$scenario"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg-$scenario" exec "$script_dir/3com.sh"
    ;;
  pcap-check)
    pcap="${2:-$evidence_dir/echo.pcap}"
    exec python3 "$script_dir/host/stage8_responder.py" --check-pcap "$pcap"
    ;;
  *)
    echo "usage: tools/stage8-mame.sh {prepare|responder SCENARIO|mame SCENARIO|pcap-check [PCAP]}" >&2
    exit 2
    ;;
esac
