# Stage 7 MAME / hardware evidence

- Date:
- Tester:
- MAME or real Sprinter/card/slot:
- Version and IMG SHA-256:
- Named host interfaces:
- Exact commands:

## Results

- [ ] static `NETCFG -i -v` and `IFUP`
- [ ] DHCP ACK
- [ ] delayed OFFER/ACK and retry
- [ ] DHCP NAK leaves dynamic environment empty
- [ ] DHCP timeout leaves dynamic environment empty
- [ ] ARP same subnet
- [ ] ARP through gateway
- [ ] limited and subnet broadcast
- [ ] unknown ARP: three bounded attempts
- [ ] link down timeout and subsequent link up
- [ ] byte-exact ARP/DHCP classic pcap without FCS
- [ ] no leaked DSS page/file/ISA window

Console output/screenshots:

Pcap paths and decoded expected/actual bytes:

Final result: PASS / FAIL / PARTIAL
