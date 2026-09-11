#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

source "$script_dir/artifacts.sh"

required_tools=(sjasmplus sprinter-mkdll z88dk-ticks mformat mcopy mdir zip unzip iconv perl node python3)
for tool in "${required_tools[@]}"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool not found in PATH: $tool" >&2
    exit 1
  fi
  echo "Found $tool: $(command -v "$tool")"
done
sjasmplus --version 2>&1 | head -n 1

bash -n "$script_dir/artifacts.sh" "$script_dir/build.sh" \
  "$script_dir/image.sh" "$script_dir/package.sh" "$script_dir/test-host.sh" \
  "$script_dir/test-stage3-asm.sh" "$script_dir/test-stage4-asm.sh" \
  "$script_dir/test-stage5-asm.sh" "$script_dir/test-stage6-asm.sh" \
  "$script_dir/test-stage7-asm.sh" "$script_dir/test-stage8-asm.sh" \
  "$script_dir/test-stage9-asm.sh" "$script_dir/stage8-mame.sh" \
  "$script_dir/stage9-mame.sh" "$script_dir/test-stage10-asm.sh" \
  "$script_dir/stage10-mame.sh" "$script_dir/test-stage11-asm.sh" \
  "$script_dir/stage11-mame.sh" "$script_dir/test-stage12-asm.sh" \
  "$script_dir/stage12-mame.sh" "$script_dir/test-stage13-asm.sh" \
  "$script_dir/stage13-mame.sh" "$script_dir/test-stage14-asm.sh" \
  "$script_dir/stage14-mame.sh"
sh -n "$script_dir/test-fixtures/fake-mame.sh"
node --check "$script_dir/exe-harness/Z80core.js"
node --check "$script_dir/exe-harness/harness.js"
node --check "$script_dir/exe-harness/run.js"
node --check "$script_dir/test-exe-harness.js"
node --check "$script_dir/test-exe-stress.js"
node --check "$script_dir/test-stage7-exe.js"
node --check "$script_dir/test-stage8-exe.js"
node --check "$script_dir/test-stage9-exe.js"
node --check "$script_dir/test-stage10-exe.js"
node --check "$script_dir/test-stage11-exe.js"
node --check "$script_dir/test-stage12-exe.js"
node --check "$script_dir/test-stage13-exe.js"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/ethernet_helper.py" "$script_dir/host/test_ethernet_helper.py" \
  "$script_dir/host/stage7_responder.py" "$script_dir/host/test_stage7_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage8_responder.py" "$script_dir/host/test_stage8_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage9_responder.py" "$script_dir/host/test_stage9_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage10_responder.py" "$script_dir/host/test_stage10_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage11_responder.py" "$script_dir/host/test_stage11_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage12_responder.py" "$script_dir/host/test_stage12_responder.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage13_responder.py" "$script_dir/host/test_stage13_responder.py" \
  "$script_dir/host/stage13_http_server.py"
python3 -c 'import ast,sys; [ast.parse(open(p, encoding="utf-8").read(), filename=p) for p in sys.argv[1:]]' \
  "$script_dir/host/stage14_responder.py" "$script_dir/host/test_stage14_responder.py"
sh -n "$script_dir/3com.sh"
input_profile="$repo_root/config/mame/sprinter.cfg"
ui_profile="$repo_root/config/mame/default.cfg"
grep -Fq '<keyboard tag=":" enabled="0" />' "$input_profile"
grep -Fq '<keyboard tag=":kbd:ms_naturl" enabled="1" />' "$input_profile"
grep -Fq 'view="Screen 0 Standard (4:3)"' "$input_profile"
grep -Fq 'KEYCODE_LCONTROL KEYCODE_DEL' "$ui_profile"
grep -Fq 'keyboardprovider sdl' "$script_dir/3com.sh"
grep -Fq -- '-kbd ms_naturl' "$script_dir/3com.sh"
grep -Fq '"$CFG_DIR/default.cfg"' "$script_dir/3com.sh"
if grep -Eq -- '-mouse(provider)?([[:space:]]|$)|-background_input' \
  "$script_dir/3com.sh"; then
  echo "Error: MAME launcher must not force mouse capture" >&2
  exit 1
fi
perl -c "$script_dir/markdown_to_text.pl" >/dev/null
perl -c "$script_dir/check-hello.pl" >/dev/null
perl -c "$script_dir/check-text.pl" >/dev/null
perl -c "$script_dir/check-stage1-audit.pl" >/dev/null
perl -c "$script_dir/check-stage3.pl" >/dev/null
perl -c "$script_dir/check-stage4.pl" >/dev/null
perl -c "$script_dir/check-stage5.pl" >/dev/null
perl -c "$script_dir/check-stage6.pl" >/dev/null
perl -c "$script_dir/check-stage7.pl" >/dev/null
perl -c "$script_dir/check-stage8.pl" >/dev/null
perl -c "$script_dir/check-stage9.pl" >/dev/null
perl -c "$script_dir/check-stage10.pl" >/dev/null
perl -c "$script_dir/check-stage11.pl" >/dev/null
perl -c "$script_dir/check-stage12.pl" >/dev/null
perl -c "$script_dir/check-stage13.pl" >/dev/null
perl -c "$script_dir/check-stage14.pl" >/dev/null
perl -c "$script_dir/set-mame-network.pl" >/dev/null
"$script_dir/test-mame-network.sh"

"$script_dir/build.sh"
perl "$script_dir/check-hello.pl" \
  "$repo_root/build/HELLO.EXE" "$repo_root/src/apps/hello.asm"
perl "$script_dir/check-stage1-audit.pl" "$repo_root/docs/STAGE1_AUDIT.md"
perl "$script_dir/check-stage3.pl" "$repo_root" EL3INFO EL3EEP ISAPROBE
"$script_dir/test-stage3-asm.sh"
perl "$script_dir/check-stage4.pl" "$repo_root"
"$script_dir/test-stage4-asm.sh"
perl "$script_dir/check-stage5.pl" "$repo_root"
"$script_dir/test-stage5-asm.sh"
"$script_dir/test-stage6-asm.sh"
perl "$script_dir/check-stage6.pl" "$repo_root"
"$script_dir/test-stage7-asm.sh"
perl "$script_dir/check-stage7.pl" "$repo_root"
"$script_dir/test-stage8-asm.sh"
perl "$script_dir/check-stage8.pl" "$repo_root"
"$script_dir/test-stage9-asm.sh"
perl "$script_dir/check-stage9.pl" "$repo_root"
"$script_dir/test-stage10-asm.sh"
perl "$script_dir/check-stage10.pl" "$repo_root"
"$script_dir/test-stage11-asm.sh"
perl "$script_dir/check-stage11.pl" "$repo_root"
"$script_dir/test-stage12-asm.sh"
perl "$script_dir/check-stage12.pl" "$repo_root"
"$script_dir/test-stage13-asm.sh"
perl "$script_dir/check-stage13.pl" "$repo_root"
"$script_dir/test-stage14-asm.sh"
perl "$script_dir/check-stage14.pl" "$repo_root"
node "$script_dir/test-exe-harness.js"
node "$script_dir/test-stage3-exe.js"
node "$script_dir/test-stage7-exe.js"
node "$script_dir/test-stage8-exe.js"
node "$script_dir/test-stage9-exe.js"
node "$script_dir/test-stage10-exe.js"
node "$script_dir/test-stage11-exe.js"
node "$script_dir/test-stage12-exe.js"
"$script_dir/test-http-stream-asm.sh"
node "$script_dir/test-stage13-exe.js"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_ethernet_helper.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage7_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage8_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage9_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage10_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage11_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage12_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage13_responder.py"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$script_dir/host" \
  python3 "$script_dir/host/test_stage14_responder.py"

artifact_validate_manifest IMG
artifact_validate_manifest ZIP

expected_img="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-img-list.XXXXXX")"
expected_zip="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-zip-list.XXXXXX")"
actual_names="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-actual-list.XXXXXX")"
text_copy="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-text.XXXXXX")"
binary_copy="$(mktemp "${TMPDIR:-/tmp}/sprinter-509b-binary.XXXXXX")"
trap 'rm -f "$expected_img" "$expected_zip" "$actual_names" "$text_copy" "$binary_copy"' EXIT

printf '%s\n' ARP.EXE ARP.TXT CONNECT.BAT DLDIRECT.EXE DLSPEED.EXE DLSPEED.TXT EL3EEP.EXE EL3INFO.EXE EL3INFO.TXT EL3LB.EXE EL3LB.TXT EL3REG.EXE EL3REG.TXT EL3RX.EXE EL3RX.TXT EL3TX.EXE EL3TX.TXT FTP.EXE FTP.TXT HELLO.EXE HOWTO.TXT IFUP.EXE IFUP.TXT ISAPROBE.EXE \
  LICENSE.TXT NETCFG.EXE NETCFG.TXT NETPROF.EXE NETSMPL.CFG NSLOOKUP.EXE NSLOOKUP.TXT NTP.EXE NTP.TXT PING.EXE PING.TXT PINGALT.EXE README.TXT READMERU.TXT S10TEST.TXT S11TEST.TXT S12TEST.TXT S13TEST.TXT S14TEST.TXT S9TEST.TXT TCPTEST.EXE TCPTEST.TXT TESTING.TXT TFTP.EXE TFTP.TXT UDPTEST.EXE UDPTEST.TXT UNET509B.DLL UNET509B.TXT UNETTEST.EXE USAGE.TXT WGET.EXE WGET.TXT \
  | LC_ALL=C sort > "$expected_img"
artifact_names IMG | LC_ALL=C sort > "$actual_names"
diff -u "$expected_img" "$actual_names"

printf '%s\n' CONNECT.BAT EL3INFO.EXE EL3INFO.TXT FTP.EXE FTP.TXT HOWTO.TXT IFUP.EXE IFUP.TXT LICENSE.TXT NETCFG.EXE NETCFG.TXT NETSMPL.CFG NSLOOKUP.EXE NSLOOKUP.TXT NTP.EXE NTP.TXT PING.EXE PING.TXT README.TXT \
  READMERU.TXT TFTP.EXE TFTP.TXT UNET509B.DLL UNET509B.TXT USAGE.TXT WGET.EXE WGET.TXT \
  | LC_ALL=C sort > "$expected_zip"
artifact_names ZIP | LC_ALL=C sort > "$actual_names"
diff -u "$expected_zip" "$actual_names"
if artifact_names ZIP | grep -Eq '^(HELLO|EL3EEP|ISAPROBE|.*TEST).*\.(EXE|COM)$'; then
  echo "Error: test program found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^EL3(LB|REG|TX|RX)\.'; then
  echo "Error: developer diagnostic found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^ARP\.'; then
  echo "Error: developer ARP diagnostic found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^(PINGALT|TESTING)\.'; then
  echo "Error: Stage 8 developer diagnostic found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^S10TEST\.'; then
  echo "Error: Stage 10 developer testing document found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^(TCPTEST|S11TEST)\.'; then
  echo "Error: Stage 11 developer artifacts found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^S12TEST\.'; then
  echo "Error: Stage 12 developer testing document found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^(DLSPEED|DLDIRECT|S13TEST)\.'; then
  echo "Error: Stage 13 developer artifacts found in ZIP manifest" >&2
  exit 1
fi
if artifact_names ZIP | grep -Eq '^(UNETTEST|S14TEST)\.'; then
  echo "Error: Stage 14 developer artifacts found in ZIP manifest" >&2
  exit 1
fi

while IFS= read -r record; do
  IFS='|' read -r kind source name <<< "$record"
  if [ ! -f "$repo_root/$source" ]; then
    echo "Error: manifest source is missing: $source" >&2
    exit 1
  fi
done < <(artifact_records IMG)

artifact_copy text "$repo_root/docs/runtime/README_RU.txt" "$text_copy" "$script_dir"
perl "$script_dir/check-text.pl" "$text_copy"
if iconv -f CP866 -t UTF-8 "$text_copy" | grep -Eqi \
  '(^|[^[:alpha:]])make([^[:alpha:]]|$)|MAME|структур[аы] репозитория|host[- ]|tools/'; then
  echo "Error: runtime README contains host/developer instructions" >&2
  exit 1
fi

for binary in HELLO EL3INFO EL3EEP EL3REG EL3LB EL3TX EL3RX ISAPROBE NETCFG IFUP ARP PING PINGALT UDPTEST TFTP NSLOOKUP NTP TCPTEST WGET FTP DLSPEED DLDIRECT UNETTEST; do
  artifact_copy binary "$repo_root/build/$binary.EXE" "$binary_copy" "$script_dir"
  cmp "$repo_root/build/$binary.EXE" "$binary_copy"
done
artifact_copy binary "$repo_root/build/UNET509B.DLL" "$binary_copy" "$script_dir"
cmp "$repo_root/build/UNET509B.DLL" "$binary_copy"

version="$(tr -d '\r\n' < "$repo_root/VERSION")"
if [ "$version" != "0.0.1" ] || ! grep -q 'PACKAGE_VERSION.*"0.0.1"' \
  "$repo_root/src/include/version.inc"; then
  echo "Error: package version declarations disagree" >&2
  exit 1
fi
for binary in EL3INFO EL3EEP EL3REG EL3LB EL3TX EL3RX ISAPROBE NETCFG IFUP ARP PING PINGALT UDPTEST TFTP NSLOOKUP NTP TCPTEST WGET FTP DLSPEED DLDIRECT UNETTEST; do
  if ! grep -a -q "v0.0.1" "$repo_root/build/$binary.EXE"; then
    echo "Error: $binary banner is not version 0.0.1" >&2
    exit 1
  fi
done
if ! grep -a -q "v0.0.1" "$repo_root/build/UNET509B.DLL"; then
  echo "Error: UNET509B.DLL name field is not version 0.0.1" >&2
  exit 1
fi

if [ "$(readlink "$repo_root/CLAUDE.md")" != "./AGENTS.md" ]; then
  echo "Error: CLAUDE.md symlink changed" >&2
  exit 1
fi

echo "Manifest: strict 8.3 names, uniqueness, required IMG files, and ZIP exclusions passed"
echo "Artifact formats: CP866/CRLF text and byte-identical binary copy passed"
echo "Host tests passed"
