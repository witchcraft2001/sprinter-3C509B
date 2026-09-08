#!/usr/bin/env bash

# Single source of truth for the diagnostic IMG and release ZIP contents.
# Record format: kind|repository source|flat 8.3 destination.

DIST_NAME="sprinter-3c509b"
ARTIFACT_MTIME="202608290000"

IMG_ARTIFACTS=(
  "binary|build/HELLO.EXE|HELLO.EXE"
  "binary|build/EL3INFO.EXE|EL3INFO.EXE"
  "binary|build/EL3EEP.EXE|EL3EEP.EXE"
  "binary|build/EL3REG.EXE|EL3REG.EXE"
  "binary|build/EL3LB.EXE|EL3LB.EXE"
  "binary|build/EL3TX.EXE|EL3TX.EXE"
  "binary|build/EL3RX.EXE|EL3RX.EXE"
  "binary|build/ISAPROBE.EXE|ISAPROBE.EXE"
  "binary|build/NETCFG.EXE|NETCFG.EXE"
  "binary|build/IFUP.EXE|IFUP.EXE"
  "binary|build/ARP.EXE|ARP.EXE"
  "binary|build/PING.EXE|PING.EXE"
  "binary|build/PINGALT.EXE|PINGALT.EXE"
  "binary|build/UDPTEST.EXE|UDPTEST.EXE"
  "binary|build/TFTP.EXE|TFTP.EXE"
  "binary|build/NSLOOKUP.EXE|NSLOOKUP.EXE"
  "binary|build/NTP.EXE|NTP.EXE"
  "binary|build/TCPTEST.EXE|TCPTEST.EXE"
  "binary|build/WGET.EXE|WGET.EXE"
  "binary|build/FTP.EXE|FTP.EXE"
  "binary|build/DLSPEED.EXE|DLSPEED.EXE"
  "binary|build/NETPROF.EXE|NETPROF.EXE"
  "text|docs/runtime/README_EN.txt|README.TXT"
  "text|docs/runtime/README_RU.txt|READMERU.TXT"
  "text|docs/EL3INFO.md|EL3INFO.TXT"
  "text|docs/EL3REG.md|EL3REG.TXT"
  "text|docs/EL3LB.md|EL3LB.TXT"
  "text|docs/EL3TX.md|EL3TX.TXT"
  "text|docs/EL3RX.md|EL3RX.TXT"
  "text|docs/NETCFG.md|NETCFG.TXT"
  "text|docs/IFUP.md|IFUP.TXT"
  "text|docs/ARP.md|ARP.TXT"
  "text|docs/PING.md|PING.TXT"
  "text|docs/UDPTEST.md|UDPTEST.TXT"
  "text|docs/TFTP.md|TFTP.TXT"
  "text|docs/NSLOOKUP.md|NSLOOKUP.TXT"
  "text|docs/NTP.md|NTP.TXT"
  "text|docs/TCPTEST.md|TCPTEST.TXT"
  "text|docs/WGET.md|WGET.TXT"
  "text|docs/FTP.md|FTP.TXT"
  "text|docs/DLSPEED.md|DLSPEED.TXT"
  "text|docs/STAGE8_TESTING_RU.md|TESTING.TXT"
  "text|docs/STAGE9_TESTING_RU.md|S9TEST.TXT"
  "text|docs/STAGE10_TESTING_RU.md|S10TEST.TXT"
  "text|docs/STAGE11_TESTING_RU.md|S11TEST.TXT"
  "text|docs/STAGE12_TESTING_RU.md|S12TEST.TXT"
  "text|docs/STAGE13_TESTING_RU.md|S13TEST.TXT"
  "text|config/CONNECT.BAT|CONNECT.BAT"
  "text|docs/USAGE.md|USAGE.TXT"
  "text|docs/HOWTO.md|HOWTO.TXT"
  "text|config/NETSMPL.CFG|NETSMPL.CFG"
  "text|LICENSE|LICENSE.TXT"
)

ZIP_ARTIFACTS=(
  "binary|build/EL3INFO.EXE|EL3INFO.EXE"
  "binary|build/NETCFG.EXE|NETCFG.EXE"
  "binary|build/IFUP.EXE|IFUP.EXE"
  "binary|build/PING.EXE|PING.EXE"
  "binary|build/TFTP.EXE|TFTP.EXE"
  "binary|build/NSLOOKUP.EXE|NSLOOKUP.EXE"
  "binary|build/NTP.EXE|NTP.EXE"
  "binary|build/WGET.EXE|WGET.EXE"
  "binary|build/FTP.EXE|FTP.EXE"
  "text|docs/runtime/README_EN.txt|README.TXT"
  "text|docs/runtime/README_RU.txt|READMERU.TXT"
  "text|docs/EL3INFO.md|EL3INFO.TXT"
  "text|docs/NETCFG.md|NETCFG.TXT"
  "text|docs/IFUP.md|IFUP.TXT"
  "text|docs/PING.md|PING.TXT"
  "text|docs/TFTP.md|TFTP.TXT"
  "text|docs/NSLOOKUP.md|NSLOOKUP.TXT"
  "text|docs/NTP.md|NTP.TXT"
  "text|docs/WGET.md|WGET.TXT"
  "text|docs/FTP.md|FTP.TXT"
  "text|config/CONNECT.BAT|CONNECT.BAT"
  "text|docs/USAGE.md|USAGE.TXT"
  "text|docs/HOWTO.md|HOWTO.TXT"
  "text|config/NETSMPL.CFG|NETSMPL.CFG"
  "text|LICENSE|LICENSE.TXT"
)

artifact_records() {
  case "$1" in
    IMG) printf '%s\n' "${IMG_ARTIFACTS[@]}" ;;
    ZIP) printf '%s\n' "${ZIP_ARTIFACTS[@]}" ;;
    *)
      echo "Error: unknown artifact scope '$1'" >&2
      return 1
      ;;
  esac
}

artifact_names() {
  local scope="$1" record kind source name
  while IFS= read -r record; do
    IFS='|' read -r kind source name <<< "$record"
    printf '%s\n' "$name"
  done < <(artifact_records "$scope")
}

artifact_validate_manifest() {
  local scope="$1" record kind source name upper seen
  seen="|"

  while IFS= read -r record; do
    IFS='|' read -r kind source name <<< "$record"
    if [ -z "$kind" ] || [ -z "$source" ] || [ -z "$name" ]; then
      echo "Error: incomplete $scope manifest record: $record" >&2
      return 1
    fi
    case "$kind" in
      text|binary) ;;
      *)
        echo "Error: invalid artifact kind '$kind' for $name" >&2
        return 1
        ;;
    esac
    if [[ ! "$name" =~ ^[A-Z0-9_]{1,8}\.[A-Z0-9_]{1,3}$ ]]; then
      echo "Error: artifact name is not strict uppercase 8.3: $name" >&2
      return 1
    fi
    upper="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
    case "$seen" in
      *"|$upper|"*)
        echo "Error: duplicate case-insensitive artifact name: $name" >&2
        return 1
        ;;
    esac
    seen="${seen}${upper}|"
  done < <(artifact_records "$scope")
}

artifact_copy() {
  local kind="$1" source="$2" destination="$3" script_dir="$4"
  local rendered dos_text source_ext

  if [ ! -f "$source" ]; then
    echo "Error: artifact source does not exist: $source" >&2
    return 1
  fi

  case "$kind" in
    binary)
      cp "$source" "$destination"
      cmp -s "$source" "$destination" || {
        echo "Error: binary artifact changed while copying: $source" >&2
        return 1
      }
      ;;
    text)
      rendered="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-render.XXXXXX")"
      dos_text="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-crlf.XXXXXX")"
      source_ext="${source##*.}"
      source_ext="$(printf '%s' "$source_ext" | tr '[:lower:]' '[:upper:]')"
      if [ "$source_ext" = "MD" ]; then
        perl "$script_dir/markdown_to_text.pl" "$source" > "$rendered"
      else
        cp "$source" "$rendered"
      fi
      LC_ALL=C awk 'BEGIN { ORS="\r\n" } { sub(/\r$/, ""); print }' \
        "$rendered" > "$dos_text"
      if ! iconv -f UTF-8 -t CP866 "$dos_text" > "$destination"; then
        echo "Error: $source cannot be represented as CP866" >&2
        rm -f "$rendered" "$dos_text" "$destination"
        return 1
      fi
      rm -f "$rendered" "$dos_text"
      ;;
    *)
      echo "Error: unsupported artifact kind '$kind'" >&2
      return 1
      ;;
  esac

  touch -t "$ARTIFACT_MTIME" "$destination"
}

artifact_stage_manifest() {
  local scope="$1" repo_root="$2" destination_root="$3" script_dir="$4"
  local record kind source name

  artifact_validate_manifest "$scope"
  mkdir -p "$destination_root"
  while IFS= read -r record; do
    IFS='|' read -r kind source name <<< "$record"
    artifact_copy "$kind" "$repo_root/$source" \
      "$destination_root/$name" "$script_dir"
  done < <(artifact_records "$scope")
}
