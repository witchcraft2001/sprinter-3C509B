# Sprinter 3C509B Network Kit

This repository develops a polling-only network kit for the Sprinter DSS and a
3Com EtherLink III 3C509B-TPO in an ISA8 slot.

Version 0.0.1 contains read-only 3C509B discovery and diagnostics, polling
`NETDRV`, DHCP acquire/renew/release, ARP, IPv4/ICMP `PING`, DNS,
`NSLOOKUP`, NTP clock setup, UDP/TFTP GET and PUT with hostname support, a
two-channel client TCP transport with FTP/DLSPEED and HTTP `WGET`, and
`UNET509B.DLL` — a libman 1.3/L1 network backend (TCP, UDP, RESOLVE, PING,
two channels, LISTEN, ASYNCSEND) for third-party applications, exercised by
`UNETTEST.EXE`. `PINGALT`, `UDPTEST`, `TCPTEST` and `UNETTEST` are
developer-IMG diagnostics. No EEPROM write or Sprinter IRQ route is
implemented.

## Build

Install `sjasmplus`, `z88dk-ticks`, mtools (`mformat`, `mcopy`, and `mdir`),
`zip`, `unzip`, `iconv`, Perl, Node.js and Python 3. Then run:

```sh
make build
make test-host
make package
make image
```

Generated files are placed under `build/` and `distr/`:

- The current DSS programs under `build/` include NETCFG, IFUP, PING, TFTP,
  NSLOOKUP and NTP, plus the read-only/developer diagnostics through TCPTEST.
- `distr/sprinter-3c509b.img` is a 1.44 MB FAT12 developer image containing
  all programs and the runtime documents/configuration. EL3LB, EL3TX, EL3RX
  and EL3REG are developer diagnostics shipped only here.
- `distr/sprinter-3c509b.zip` contains EL3INFO, NETCFG, IFUP, PING, TFTP,
  NSLOOKUP and NTP, and excludes developer/test programs.

The text files inside IMG and ZIP are flat, strict 8.3 names encoded as CP866
with CRLF line endings. Binary artifacts are copied byte for byte. See
`docs/QUICKSTART_RU.md` for the Russian quick start and
`docs/MAME_STAGE0.md` for developer-only emulator instructions.

## Scope and safety

specs.md is the authoritative specification and acceptance log. Local code and
documentation do not replace MAME or real-card evidence. Sprinter ISA interrupt
routing is intentionally absent; every wait is bounded and EEPROM is read-only.

## License

BSD-3-Clause. The minimal DSS include/macro scaffolding retains attribution to
Roman Boykov. The host-only Z80 core is MIT licensed by Molly Howell; see
`LICENSE`, `THIRD_PARTY.md`, and the source headers.
