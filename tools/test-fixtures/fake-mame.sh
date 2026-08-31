#!/bin/sh
set -eu

cfg=
provider=
listnetwork=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -cfg_directory) cfg=$2; shift 2 ;;
    -networkprovider) provider=$2; shift 2 ;;
    -listnetwork) listnetwork=1; shift ;;
    *) shift ;;
  esac
done
[ "$provider" = pcap ] || { echo "fake-mame: provider is not pcap" >&2; exit 3; }
if [ "$listnetwork" = 1 ]; then
  printf '%s\n' 'Available network interfaces:' '    feth0' '    feth1' '    bridge with spaces'
  exit 0
fi
[ -n "$cfg" ] || { echo "fake-mame: cfg directory missing" >&2; exit 3; }
grep -Eq '<device tag=":isa[01]:3c509b" interface="[012]" />' "$cfg/sprinter.cfg"
