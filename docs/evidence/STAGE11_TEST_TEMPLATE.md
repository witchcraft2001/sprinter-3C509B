# Stage 11 MAME acceptance — YYYY-MM-DD

- Result: PASS / FAIL
- Environment: Sprinter MAME, responder interface, MAME interface
- Image: `build/stage11-mame/stage11-tcp.img`
- Responder profile: clean / faults / zero / reset
- Pcap: `evidence/stage11/stage11-PROFILE.pcap`
- Screenshots: ____________________

## DSS results

- Validation floppy selected, `DIR` lists `TCPTEST.EXE`: ____________________
- Two simultaneous channels: ____________________
- Lengths 0/1/535/536/537/2048/4096: ____________________
- MSS 536 and long-buffer segmentation: ____________________
- Duplicate/out-of-order/retransmit: ____________________
- Zero-window recovery: ____________________
- Remote RST and reconnect: ____________________
- Esc and Ctrl+C cancellation: ____________________
- Bounded close with FIN: ____________________

## Responder and pcap evidence

- Responder log: ____________________
- Pcap check: ____________________
- Required log tags `READY SYN ESTABLISHED DATA FIN`: ____________________
- Fault tags `DROP OUT-OF-ORDER DUPLICATE WINDOW RST`: ____________________

## SHA-256

- IMG: ____________________
- TCPTEST.EXE: ____________________

## Open item

Real Sprinter/3C509B hardware acceptance remains open.
