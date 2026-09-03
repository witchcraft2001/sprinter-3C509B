#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage11-mame"
image="$stage_dir/stage11-tcp.img"
profile="${2:-faults}"
responder_if="${STAGE11_RESPONDER_INTERFACE:-feth1}"
mame_if="${STAGE11_MAME_INTERFACE:-feth0}"
evidence_dir="${STAGE11_EVIDENCE_DIR:-$repo_root/evidence/stage11}"

check_stage_dir_writable() {
  if [ -e "$stage_dir" ] && [ ! -w "$stage_dir" ]; then
    echo "Stage 11 directory is not writable: $stage_dir" >&2
    echo "Fix ownership once, then rerun without sudo:" >&2
    echo "  sudo chown -R \"$(id -u):$(id -g)\" \"$stage_dir\"" >&2
    exit 1
  fi
}

case "${1:-}" in
  prepare)
    check_stage_dir_writable
    mkdir -p "$stage_dir"
    "$script_dir/image.sh"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE8.CFG" ::NET.CFG
    echo "Prepared $image with static 192.168.7.20/24 configuration"
    ;;
  responder)
    case "$profile" in
      clean|faults|zero|reset) ;;
      *) echo "unknown profile: $profile" >&2; exit 2 ;;
    esac
    mkdir -p "$evidence_dir"
    exec python3 "$script_dir/host/stage11_responder.py" \
      --profile "$profile" --interface "$responder_if" \
      --pcap "$evidence_dir/stage11-$profile.pcap"
    ;;
  mame)
    if [ ! -f "$image" ]; then
      echo "Run tools/stage11-mame.sh prepare first" >&2
      exit 2
    fi
    if [ -f "$repo_root/distr/sprinter-3c509b.img" ] &&
       [ "$image" -ot "$repo_root/distr/sprinter-3c509b.img" ]; then
      echo "Stage 11 MAME image is older than distr/sprinter-3c509b.img" >&2
      echo "Run tools/stage11-mame.sh prepare after rebuilding, then rerun mame" >&2
      exit 2
    fi
    mkdir -p "$stage_dir/cfg"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg" exec "$script_dir/3com.sh"
    ;;
  pcap-check)
    pcap="${2:-$evidence_dir/stage11-faults.pcap}"
    exec python3 "$script_dir/host/stage11_responder.py" --check-pcap "$pcap"
    ;;
  *)
    echo "usage: tools/stage11-mame.sh {prepare|responder [clean|faults|zero|reset]|mame|pcap-check [PCAP]}" >&2
    exit 2
    ;;
esac
