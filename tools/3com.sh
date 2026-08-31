#!/bin/sh
set -eu

# Launch the Stage 3 discovery image without changing MAME or host networking.
# MAME_3C509B_SLOT selects the tested Sprinter ISA slot; slot 1 is the default.
# MAME_3C509B_CARD=absent omits only the tested card for the no-card case.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RELEASE_DIR=${MAME_RELEASE_DIR:-"$PROJECT_DIR/../mame_images/mame_release_v306_25.05.2025"}
MAME_BIN=${MAME_BIN:-"$RELEASE_DIR/mame"}
IMAGE_PATH=${SPRINTER_3C509B_IMG:-"$PROJECT_DIR/distr/sprinter-3c509b.img"}
CFG_DIR=${MAME_CFG_DIR:-"$PROJECT_DIR/.mame-cfg"}
CFG_TEMPLATE="$PROJECT_DIR/config/mame/sprinter.cfg"
DEFAULT_CFG_TEMPLATE="$PROJECT_DIR/config/mame/default.cfg"
TEST_SLOT=${MAME_3C509B_SLOT:-1}
CARD_STATE=${MAME_3C509B_CARD:-present}

case "$TEST_SLOT" in
  0|1) ;;
  *)
    echo "3com.sh: MAME_3C509B_SLOT must be 0 or 1" >&2
    exit 2
    ;;
esac

case "$CARD_STATE" in
  present|absent) ;;
  *)
    echo "3com.sh: MAME_3C509B_CARD must be present or absent" >&2
    exit 2
    ;;
esac

if [ ! -x "$MAME_BIN" ]; then
  echo "3com.sh: MAME executable not found: $MAME_BIN" >&2
  exit 1
fi
if [ ! -f "$IMAGE_PATH" ]; then
  echo "3com.sh: DSS image not found: $IMAGE_PATH" >&2
  exit 1
fi
if [ ! -f "$CFG_TEMPLATE" ]; then
  echo "3com.sh: MAME input profile not found: $CFG_TEMPLATE" >&2
  exit 1
fi
if [ ! -f "$DEFAULT_CFG_TEMPLATE" ]; then
  echo "3com.sh: MAME UI profile not found: $DEFAULT_CFG_TEMPLATE" >&2
  exit 1
fi
mkdir -p "$CFG_DIR"
cp "$CFG_TEMPLATE" "$CFG_DIR/sprinter.cfg"
cp "$DEFAULT_CFG_TEMPLATE" "$CFG_DIR/default.cfg"

if [ -n "${MAME_NETWORK_INTERFACE:-}" ]; then
  network_provider=${MAME_NETWORK_PROVIDER:-pcap}
  network_list=$("$MAME_BIN" -networkprovider "$network_provider" -listnetwork 2>&1)
  network_index=$(printf '%s\n' "$network_list" | awk -v wanted="$MAME_NETWORK_INTERFACE" '
    /^Available network interfaces:/ { listed=1; ordinal=0; next }
    listed && NF {
      name=$0
      sub(/^[[:space:]]+/, "", name)
      sub(/[[:space:]]+$/, "", name)
      if (name == wanted) { print ordinal; found=1; exit }
      ordinal++
    }
    END { if (!found) exit 1 }
  ') || {
    echo "3com.sh: MAME_NETWORK_INTERFACE is not present in mame -listnetwork: $MAME_NETWORK_INTERFACE" >&2
    exit 2
  }
  network_tag=":isa${TEST_SLOT}:3c509b"
  perl "$SCRIPT_DIR/set-mame-network.pl" "$CFG_DIR/sprinter.cfg" \
    "$network_tag" "$network_index"
  MAME_NETWORK_PROVIDER=$network_provider
fi

set -- sprinter \
  -rompath "$RELEASE_DIR/roms" \
  -cfg_directory "$CFG_DIR" \
  -skip_gameinfo -video opengl -window -nofilter \
  -keyboardprovider sdl -kbd ms_naturl \
  -view "Screen 0 Standard (4:3)" \
  -beta:wd179x:0 525qd -beta:wd179x:1 35hd -flop2 "$IMAGE_PATH" "$@"

if [ "$TEST_SLOT" = 0 ]; then
  if [ "$CARD_STATE" = present ]; then
    set -- "$@" -isa0 3c509b
  fi
else
  set -- "$@" -isa0 zxbus_adapter \
    -isa0:zxbus_adapter:card neogs
  if [ "$CARD_STATE" = present ]; then
    set -- "$@" -isa1 3c509b
  fi
fi

set -- "$@" \
  -hard1 "$RELEASE_DIR/IMG/sp_hdd_sys.chd" \
  -hard2 "$RELEASE_DIR/IMG/sp_hdd_media.chd" \
  -ata2:0 cdrom -cdrom "$RELEASE_DIR/IMG/SprinterCD.iso" \
  -bios v3.06

if [ -n "${MAME_NETWORK_PROVIDER:-}" ]; then
  set -- "$@" -networkprovider "$MAME_NETWORK_PROVIDER"
fi

if [ "${MAME_DEBUG:-0}" = 1 ]; then
  set -- "$@" -debug
fi

exec "$MAME_BIN" "$@"
