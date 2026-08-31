# Safe hardware setup

Before using a real Sprinter, record the card label, physical slot, ID port and
base. Begin with read-only `EL3INFO`; do not blind-scan ISA space. EEPROM is
never written and the IRQ shown by diagnostics is not connected or used.

Place `NET.CFG` beside `NETCFG.EXE`. For DHCP use `IP=DHCP`; for static mode set
`IP`, `NETMASK`, and optionally `GATEWAY`, `DNS1`, and `DNS2`. Run
`NETCFG -i -v`, then `IFUP`. `CONNECT.BAT` performs the non-verbose two-command
sequence after the configuration has been reviewed.

If a timeout or unexpected status occurs, stop. The program closes the ISA
window, releases its DSS page, prints `RESULT FAIL`, and returns control to DSS.
