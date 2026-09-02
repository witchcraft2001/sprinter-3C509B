# Stage 10 MAME acceptance — YYYY-MM-DD

- Result: PASS / FAIL
- Environment: Sprinter MAME, responder interface, MAME interface
- Image: `build/stage10-mame/stage10-dhcp.img`
- Responder: `sudo tools/stage10-mame.sh responder faults`
- Pcap: `evidence/stage10/stage10-faults.pcap`
- Screenshots: ____________________

## DSS results

- `NETCFG -i`: ____________________
- DHCP acquire: ____________________
- DHCP renewal: ____________________
- `NSLOOKUP echo.stage10.test`: ____________________
- hostname PING/UDPTEST: ____________________
- hostname TFTP GET/PUT: ____________________
- local NTP with `TZ=+5:45`: ____________________
- public `NSLOOKUP example.com 1.1.1.1`: ____________________
- public `NTP pool.ntp.org`: ____________________
- DHCP release and cleared environment: ____________________

## Responder and pcap evidence

- Responder log: ____________________
- `tools/stage10-mame.sh verify`: ____________________
- `tools/stage10-mame.sh pcap-check`: ____________________
- Required log tags `READY FRAME DROP RETRY DHCP DNS NTP RELEASE PROXY`:
  ____________________

## SHA-256

- IMG: ____________________
- IFUP.EXE: ____________________
- NSLOOKUP.EXE: ____________________
- NTP.EXE: ____________________
- PING.EXE: ____________________
- UDPTEST.EXE: ____________________
- TFTP.EXE: ____________________

## Open item

Real Sprinter/3C509B hardware acceptance remains open.
