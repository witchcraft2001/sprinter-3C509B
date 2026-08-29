#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

for tool in mformat mcopy iconv perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is required but was not found in PATH" >&2
    exit 1
  fi
done

"$script_dir/build.sh"

image_path="$repo_root/distr/$DIST_NAME.img"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/sprinter-509b-image.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

artifact_stage_manifest IMG "$repo_root" "$stage_dir" "$script_dir"
mkdir -p "$repo_root/distr"
rm -f "$image_path"
mformat -C -i "$image_path" -f 1440 -N 0x3c509b00 ::

for staged_file in "$stage_dir"/*; do
  mcopy -i "$image_path" -o -m "$staged_file" "::$(basename "$staged_file")"
done

echo "Created FAT12 image distr/$DIST_NAME.img"
