#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

for tool in zip iconv perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: $tool is required but was not found in PATH" >&2
    exit 1
  fi
done

"$script_dir/build.sh"

package_root="$repo_root/build/package/$DIST_NAME"
zip_path="$repo_root/distr/$DIST_NAME.zip"

rm -rf "$package_root"
mkdir -p "$package_root" "$repo_root/distr"
artifact_stage_manifest ZIP "$repo_root" "$package_root" "$script_dir"

rm -f "$zip_path"
(
  cd "$package_root"
  TZ=UTC zip -X -q "$zip_path" ./*
)

echo "Created distr/$DIST_NAME.zip"
