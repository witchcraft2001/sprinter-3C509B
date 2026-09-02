#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage10-mame"
image="$stage_dir/stage10-dhcp.img"
fixture_dir="$stage_dir/fixtures"
upload_dir="$stage_dir/uploads"
profile="${2:-faults}"
responder_if="${STAGE10_RESPONDER_INTERFACE:-feth1}"
mame_if="${STAGE10_MAME_INTERFACE:-feth0}"
evidence_dir="${STAGE10_EVIDENCE_DIR:-$repo_root/evidence/stage10}"

check_stage_dir_writable() {
  if [ -e "$stage_dir" ] && [ ! -w "$stage_dir" ]; then
    echo "Stage 10 directory is not writable: $stage_dir" >&2
    echo "Fix ownership once, then rerun without sudo:" >&2
    echo "  sudo chown -R \"$(id -u):$(id -g)\" \"$stage_dir\"" >&2
    exit 1
  fi
}

case "${1:-}" in
  prepare)
    check_stage_dir_writable
    mkdir -p "$stage_dir" "$fixture_dir" "$upload_dir"
    "$script_dir/image.sh"
    python3 "$script_dir/host/stage10_responder.py" --prepare-fixtures "$fixture_dir"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE10.CFG" ::NET.CFG
    mcopy -i "$image" -o "$fixture_dir/S9PUT.BIN" ::S9PUT.BIN
    echo "Prepared $image with DHCP, deterministic DNS/NTP and TFTP PUT fixture"
    ;;
  responder)
    case "$profile" in clean|faults) ;; *) echo "unknown profile: $profile" >&2; exit 2;; esac
    mkdir -p "$evidence_dir" "$upload_dir"
    exec python3 "$script_dir/host/stage10_responder.py" \
      --profile "$profile" --interface "$responder_if" \
      --upload-dir "$upload_dir" --pcap "$evidence_dir/stage10-$profile.pcap"
    ;;
  mame)
    if [ ! -f "$image" ]; then
      echo "Run tools/stage10-mame.sh prepare first" >&2
      exit 2
    fi
    if [ -f "$repo_root/distr/sprinter-3c509b.img" ] &&
       [ "$image" -ot "$repo_root/distr/sprinter-3c509b.img" ]; then
      echo "Stage 10 MAME image is older than distr/sprinter-3c509b.img" >&2
      echo "Run tools/stage10-mame.sh prepare after rebuilding, then rerun mame" >&2
      exit 2
    fi
    mkdir -p "$stage_dir/cfg"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg" exec "$script_dir/3com.sh"
    ;;
  verify)
    if [ ! -f "$image" ] || [ ! -f "$fixture_dir/S9GET.BIN" ]; then
      echo "Run tools/stage10-mame.sh prepare first" >&2
      exit 2
    fi
    extracted="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-stage10-get.XXXXXX")"
    trap 'rm -f "$extracted"' EXIT
    mcopy -i "$image" -o ::S9GET.BIN "$extracted"
    cmp "$fixture_dir/S9GET.BIN" "$extracted"
    if [ ! -f "$upload_dir/S9PUT.BIN" ]; then
      echo "Missing responder upload $upload_dir/S9PUT.BIN" >&2
      exit 1
    fi
    cmp "$fixture_dir/S9PUT.BIN" "$upload_dir/S9PUT.BIN"
    echo "VERIFY OK Stage 10 hostname TFTP GET and PUT fixtures are byte-exact"
    ;;
  pcap-check)
    pcap="${2:-$evidence_dir/stage10-faults.pcap}"
    exec python3 "$script_dir/host/stage10_responder.py" --check-pcap "$pcap"
    ;;
  *)
    echo "usage: tools/stage10-mame.sh {prepare|responder [clean|faults]|mame|verify|pcap-check [PCAP]}" >&2
    exit 2
    ;;
esac
