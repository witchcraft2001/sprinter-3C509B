# Stage 9 MAME / hardware evidence

- Date:
- Tester:
- MAME or real Sprinter/card/slot/base:
- Version and IMG/UDPTEST/TFTP SHA-256:
- Named interfaces (`feth0`/`feth1` or actual names):
- Exact responder and MAME commands:

## Results

- [ ] `UDPTEST -n 10 -l 1472` returns all ten byte-exact replies
- [ ] TFTP GET through port 6969 survives deterministic loss/duplicate/reorder
- [ ] TFTP PUT is byte-exact
- [ ] existing GET refusal returns `code=23`, exit 7, and preserves the file
- [ ] GET `-y` replaces the file byte-exactly
- [ ] responder log contains `READY`, `FRAME`, `DROP`, `RETRY`, and `TFTP`
- [ ] unknown TID receives TFTP ERROR 5 without disrupting the transfer
- [ ] `tools/stage9-mame.sh verify` reports `VERIFY OK`
- [ ] classic pcap passes exact lengths/checksums, no FCS
- [ ] ISA window is closed, file handle is closed and DSS page is released

Console output/screenshots:

Responder log and pcap paths:

Decoded expected/actual bytes and SHA-256:

Final result: PASS / FAIL / PARTIAL
