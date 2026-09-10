#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
stage_dir="$repo_root/build/stage14-mame"
image="$stage_dir/stage14-unet.img"
mame_if="${STAGE14_MAME_INTERFACE:-feth0}"
sprinter_ip="192.168.7.21"
host_ip="192.168.7.44"

usage() {
  echo "usage: tools/stage14-mame.sh {prepare|mame|responder MODE [ARGS...]}" >&2
  echo "  prepare              build a Stage 14 image with UNET509B.DLL/UNETTEST.EXE and NET.CFG" >&2
  echo "  mame                 launch MAME against that image" >&2
  echo "  responder tcp-echo --port PORT       for plain 'UNETTEST $host_ip PORT'" >&2
  echo "  responder tcp-refuse --port PORT     for CONNECT-refused (NERR_CONNECT)" >&2
  echo "  responder tcp-stall --port PORT      for 'UNETTEST -a $host_ip PORT'" >&2
  echo "  responder udp-echo --port PORT       for 'UNETTEST -u PORT'" >&2
  echo "  responder dual --control-port P1 --data-port P2   for 'UNETTEST -2 P2 $host_ip P1'" >&2
  echo "  responder listen-client --port PORT  for 'UNETTEST -l PORT' (host connects to $sprinter_ip)" >&2
  exit 2
}

case "${1:-}" in
  prepare)
    mkdir -p "$stage_dir"
    "$script_dir/image.sh"
    cp "$repo_root/distr/sprinter-3c509b.img" "$image"
    mcopy -i "$image" -o "$repo_root/config/STAGE14.CFG" ::NET.CFG
    echo "Prepared $image (Sprinter IP $sprinter_ip, host peer IP $host_ip)"
    ;;
  mame)
    [ -f "$image" ] || { echo "Run tools/stage14-mame.sh prepare first" >&2; exit 2; }
    mkdir -p "$stage_dir/cfg"
    SPRINTER_3C509B_IMG="$image" MAME_NETWORK_INTERFACE="$mame_if" \
      MAME_CFG_DIR="$stage_dir/cfg" exec "$script_dir/3com.sh"
    ;;
  responder)
    mode="${2:-}"
    [ -n "$mode" ] || usage
    shift 2
    case "$mode" in
      listen-client)
        exec python3 "$script_dir/host/stage14_responder.py" listen-client \
          --host "$sprinter_ip" "$@"
        ;;
      tcp-echo|tcp-refuse|tcp-stall|udp-echo|dual)
        exec python3 "$script_dir/host/stage14_responder.py" "$mode" --bind "$host_ip" "$@"
        ;;
      *)
        usage
        ;;
    esac
    ;;
  *)
    usage
    ;;
esac
