#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v sjasmplus >/dev/null 2>&1; then
  echo "Error: sjasmplus is required but was not found in PATH" >&2
  exit 1
fi

mkdir -p "$repo_root/build"

sjasmplus --nologo --fullpath \
  -I "$repo_root/src/include" \
  --lst="$repo_root/build/HELLO.lst" \
  --raw="$repo_root/build/HELLO.EXE" \
  "$repo_root/src/apps/hello.asm"

echo "Built build/HELLO.EXE"
