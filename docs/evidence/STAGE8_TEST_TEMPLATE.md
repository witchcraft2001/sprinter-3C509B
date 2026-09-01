# Stage 8 MAME / hardware evidence

- Date:
- Tester:
- MAME or real Sprinter/card/slot:
- Version and IMG/PING/PINGALT SHA-256:
- Named interfaces (`feth0`/`feth1` or actual names):
- Exact responder and MAME commands:

## Results

- [ ] direct peer `192.168.7.44`
- [ ] gateway `192.168.7.1`
- [ ] routed external peer `203.0.113.10`
- [ ] payload 0/1/32/1472
- [ ] TTL 1/255
- [ ] bad IPv4 checksum, bad ICMP checksum and unrelated reply before success
- [ ] related Destination Unreachable (`code=24`, DSS exit 6)
- [ ] complete timeout (`code=14`, DSS exit 3) without a hang
- [ ] PINGALT direct and routed paths
- [ ] `PING -t` cancellation (`code=23`, DSS exit 7)
- [ ] 100 MAME requests without loss, leak or hang (automatic gate: 1000)
- [ ] byte-exact ARP/IPv4/ICMP classic pcap, exact captured/wire lengths, no FCS
- [ ] ISA closed and DSS page released on every exit

Console output/screenshots:

Pcap paths and decoded expected/actual bytes:

Final result: PASS / FAIL / PARTIAL
