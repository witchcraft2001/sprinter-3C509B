Sprinter 3C509B Network Kit 0.0.1

Available DSS commands:

  EL3INFO              Find a 3C509B and show its configuration.
  EL3INFO -v           Show additional read-only EEPROM fields.
  EL3EEP               Dump all 64 EEPROM words (developer diagnostic).
  ISAPROBE             Show help only.
  NETCFG               Show the published NET_* environment.
  NETCFG -i -v         Validate NET.CFG/card and publish it.
  IFUP                 Check static setup or acquire a fresh DHCP lease.
  PING target          Send bounded IPv4 ICMP Echo Requests.
  ARP [-v] target      Bounded ARP diagnostic (developer image only).
  PINGALT target       Independent polling diagnostic (developer IMG only).

EL3EEP, ISAPROBE, ARP, and PINGALT are present only on the developer disk image.
ISAPROBE reads ISA bytes only when slot, base, and count are all explicit:

  ISAPROBE -s 1 -b #0300 -n #0010

Copy NETSMPL.CFG to NET.CFG beside NETCFG.EXE and edit it before NETCFG -i.
NETCFG.TXT, IFUP.TXT, PING.TXT, USAGE.TXT, and HOWTO.TXT describe the network setup.
LICENSE.TXT contains the license.

WARNING: EEPROM access is read-only. None of these commands saves card
settings. ISAPROBE never writes ISA data, but reads of unknown hardware can
have side effects; use only a range you identified beforehand.

IFUP supports static setup and initial DHCP acquire. PING accepts dotted IPv4
addresses; DNS names, DHCP renewal and release are not implemented yet.
