#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is required but was not found in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

build_app()
{
  source_name="$1"
  artifact_name="$2"
  sjasmplus --nologo --fullpath \
    -I "$repo_root/src/include" \
    -I "$repo_root/src/lib" \
    --lst="$repo_root/build/$artifact_name.lst" \
    --raw="$repo_root/build/$artifact_name.EXE" \
    "$repo_root/src/apps/$source_name.asm"
  echo "Built build/$artifact_name.EXE"
}

build_app hello HELLO
build_app el3info EL3INFO
build_app el3eep EL3EEP
build_app el3reg EL3REG
build_app isaprobe ISAPROBE
