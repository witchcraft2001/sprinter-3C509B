# Safe hardware setup

Before using a real Sprinter, record the card label, physical slot, ID port and
base. Begin with read-only `EL3INFO`; do not blind-scan ISA space. EEPROM is
never written and the IRQ shown by diagnostics is not connected or used.

Place `NET.CFG` beside `NETCFG.EXE`. For DHCP use `IP=DHCP`; for static mode set
`IP`, `NETMASK`, and optionally `GATEWAY`, `DNS1`, and `DNS2`. Run
`NETCFG -i -v`, then `IFUP`. `CONNECT.BAT` performs the non-verbose two-command
sequence after the configuration has been reviewed.

After `IFUP` reports success, verify IPv4 routing with `PING 192.168.7.1` or
another address. Use `NSLOOKUP name` to verify DNS, and then the same hostname
with PING, UDPTEST, or TFTP. `PING -t target` runs until Esc or Ctrl-C.

For DHCP, `IFUP -r` renews the current lease without discarding it on timeout;
`IFUP -d` sends a best-effort RELEASE and clears the dynamic fields. Use `NTP`
to query `NET_NTP`, apply `NET_TZ`, and set the DSS clock. Timezone examples
are `+5:45`, `+9:30`, `+12:45`, and `-3:30`.

For TFTP, use `TFTP host GET remote` or `TFTP host PUT local`. Add
`:port` for a nonstandard request port and `-o name` to select the other file
name. GET asks before replacing an existing local file; `-y` or `-f` permits
replacement without the prompt. Interrupted or failed GET files are retained
as partial data so they can be inspected.

If a timeout or unexpected status occurs, stop. The program closes the ISA
window, releases its DSS page, prints `RESULT FAIL`, and returns control to DSS.
