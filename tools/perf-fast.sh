#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
fast_dir="$repo_root/build/perf-fast"
image_path="$fast_dir/sprinter-3c509b-fast.img"

source "$script_dir/artifacts.sh"

for tool in mformat mcopy iconv perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is required but was not found in PATH" >&2
    exit 1
  fi
done

BUILD_DIR="$fast_dir" TCPX_UNCHECKED_DATA_RX=1 "$script_dir/build.sh"

stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-fast.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
artifact_validate_manifest IMG
mkdir -p "$stage_dir"
while IFS= read -r record; do
  IFS='|' read -r kind source name <<< "$record"
  if [ "$kind" = binary ] && [[ "$source" == build/* ]]; then
    source="build/perf-fast/${source#build/}"
  fi
  artifact_copy "$kind" "$repo_root/$source" "$stage_dir/$name" "$script_dir"
done < <(artifact_records IMG)

# This image exists specifically for the Stage 13/14 MAME throughput pair,
# so make it directly bootable on that fixture network. It remains outside
# the release manifest; the normal diagnostic IMG still ships only NETSMPL.CFG.
artifact_copy text "$repo_root/config/STAGE13.CFG" "$stage_dir/NET.CFG" "$script_dir"

rm -f "$image_path"
mformat -C -i "$image_path" -f 1440 -N 0x3c509bfa ::
for staged_file in "$stage_dir"/*; do
  mcopy -i "$image_path" -o -m "$staged_file" "::$(basename "$staged_file")"
done

echo "Created non-release fast image build/perf-fast/$(basename "$image_path")"
