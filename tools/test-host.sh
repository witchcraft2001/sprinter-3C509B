#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

required_tools=(sjasmplus mformat mcopy mdir zip unzip iconv perl)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool not found in PATH: $tool" >&2
    exit 1
  fi
  echo "Found $tool: $(command -v "$tool")"
done
sjasmplus --version 2>&1 | head -n 1

bash -n "$script_dir/artifacts.sh" "$script_dir/build.sh" \
  "$script_dir/image.sh" "$script_dir/package.sh" "$script_dir/test-host.sh"
perl -c "$script_dir/markdown_to_text.pl" >/dev/null
perl -c "$script_dir/check-hello.pl" >/dev/null
perl -c "$script_dir/check-text.pl" >/dev/null
perl -c "$script_dir/check-stage1-audit.pl" >/dev/null

"$script_dir/build.sh"
perl "$script_dir/check-hello.pl" \
  "$repo_root/build/HELLO.EXE" "$repo_root/src/apps/hello.asm"
perl "$script_dir/check-stage1-audit.pl" "$repo_root/docs/STAGE1_AUDIT.md"

artifact_validate_manifest IMG
artifact_validate_manifest ZIP

expected_img="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-img-list.XXXXXX")"
expected_zip="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-zip-list.XXXXXX")"
actual_names="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-actual-list.XXXXXX")"
text_copy="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-text.XXXXXX")"
binary_copy="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-binary.XXXXXX")"
trap 'rm -f "$expected_img" "$expected_zip" "$actual_names" "$text_copy" "$binary_copy"' EXIT

printf '%s\n' HELLO.EXE LICENSE.TXT NETSMPL.CFG README.TXT READMERU.TXT \
  | LC_ALL=C sort > "$expected_img"
artifact_names IMG | LC_ALL=C sort > "$actual_names"
diff -u "$expected_img" "$actual_names"

printf '%s\n' LICENSE.TXT NETSMPL.CFG README.TXT READMERU.TXT \
  | LC_ALL=C sort > "$expected_zip"
artifact_names ZIP | LC_ALL=C sort > "$actual_names"
diff -u "$expected_zip" "$actual_names"
if artifact_names ZIP | grep -Eq '(^|/)(HELLO|.*TEST).*\.(EXE|COM)$'; then
  echo "Error: test program found in ZIP manifest" >&2
  exit 1
fi

while IFS= read -r record; do
  IFS='|' read -r kind source name <<< "$record"
  if [ ! -f "$repo_root/$source" ]; then
    echo "Error: manifest source is missing: $source" >&2
    exit 1
  fi
done < <(artifact_records IMG)

artifact_copy text "$repo_root/docs/QUICKSTART_RU.md" "$text_copy" "$script_dir"
perl "$script_dir/check-text.pl" "$text_copy"
iconv -f CP866 -t UTF-8 "$text_copy" >/dev/null

artifact_copy binary "$repo_root/build/HELLO.EXE" "$binary_copy" "$script_dir"
cmp "$repo_root/build/HELLO.EXE" "$binary_copy"

version="$(tr -d '\r\n' < "$repo_root/VERSION")"
if [ "$version" != "0.0.1" ] || ! grep -q 'PACKAGE_VERSION.*"0.0.1"' \
  "$repo_root/src/include/version.inc"; then
  echo "Error: package version declarations disagree" >&2
  exit 1
fi

echo "Manifest: strict 8.3 names, uniqueness, required IMG files, and ZIP exclusions passed"
echo "Artifact formats: CP866/CRLF text and byte-identical binary copy passed"
echo "Host tests passed"
