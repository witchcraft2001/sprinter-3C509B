Sprinter 3C509B Network Kit 0.0.1

Available DSS commands:

  EL3INFO              Find a 3C509B and show its configuration.
  EL3INFO -v           Show additional read-only EEPROM fields.
  EL3EEP               Dump all 64 EEPROM words (developer diagnostic).
  ISAPROBE             Show help only.

EL3EEP and ISAPROBE are present only on the developer disk image.
ISAPROBE reads ISA bytes only when slot, base, and count are all explicit:

  ISAPROBE -s 1 -b #0300 -n #0010

EL3INFO.TXT describes options and result codes. NETSMPL.CFG is the future
network configuration example. LICENSE.TXT contains the license. README.TXT
and READMERU.TXT contain the English and Russian on-computer instructions.

WARNING: EEPROM access is read-only. None of these commands saves card
settings. ISAPROBE never writes ISA data, but reads of unknown hardware can
have side effects; use only a range you identified beforehand.

There are no network commands in this bootstrap version.
