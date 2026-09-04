# Stage 12 MAME acceptance — 2026-09-04

- Commit: working tree on top of `caedeebc` (Stage 12 WGET changes uncommitted
  at the time of this record: `src/apps/wget.asm`, `src/lib/stage12_dns.asm`,
  `src/include/memory.inc`/`dss.inc`, `tools/check-stage12.pl`,
  `tools/host/stage12_responder.py`, `tools/exe-harness/harness.js`, and the
  WIN1/WIN2 relocation of the whole memory map).
- Emulator/DSS: MAME `0.287 (mame0238-17481-gcd34cb6a944-dirty)`, Sprinter BIOS
  `v3.06`, DSS `1.70` (OEM string on `sp_hdd_sys.chd`'s boot sector).
- Image SHA-256: `b74ef67e21fb3f2051f69f1a9ebce7a79516a7ad25ab6d410f57e5093159fcfd`
  (`build/stage12-mame/stage12-wget.img`, final state after both sessions below).
- WGET.EXE SHA-256: `897f0719fbd1a503180abb6cbf1fd692ce429130ac4fcc78f3e7dfdf310aa310`
- Sibling reference: `sprinter-rtl8019a@9ec98b0`
- **Evidence spans two responder sessions, not one continuous capture** — the
  responder was restarted between them for an unrelated re-test, which
  truncates its pcap/log. Session A covers every scenario except the plain
  `LARGE.BIN` download, which had already passed once but needed re-confirming
  against the final binary; Session B is that one re-run. The FAT12 image
  itself was never recreated between the two, so its file contents are the
  union of both and were re-verified as a whole after Session B.
  - Session A (comprehensive): pcap SHA-256
    `522443d37b7372e2bdc811b4479bf69b6bcf33b65ce3b44f36c0b3a6df147c41`
    (`PCAP OK frames=2538 tcp=1851 http_bytes=1117`, includes DNS, ARP,
    MSS-536 SYN, `GET`/`Host:`, and `Range: bytes=65536-`). Log/pcap files
    from this session were overwritten by Session B's responder restart and
    are not separately retained; the hash above is what `pcap-check` printed
    while they existed.
  - Session B (`LARGE.BIN` re-run only): responder log
    `evidence/stage12/stage12.log` (SHA-256
    `bd0e1e5fc553399f449e5b0acb3933ff701c661ccaa5177d0a1a0640197a8219`), pcap
    `evidence/stage12/stage12.pcap` (SHA-256
    `7d338bf43565bfa3cfb5de9265a93ef799df94f057a31725c3fd91a8bd68ddfa`).
    `tools/stage12-mame.sh pcap-check` on this file alone fails the
    `Range: bytes=65536-` assertion by design (that scenario wasn't repeated in
    this session); DNS/SYN/GET evidence for the retest itself is present.
- Screenshots (`Скриншоты/`, chronological):
  `2026-09-04_21-03-59 (2).png`, `2026-09-04_21-05-18 (2).png` — hostname
  ZERO/SMALL/LARGE and the IP-literal control case;
  `2026-09-04_21-33-26 (2).png` — prompt `O/R/C` (resume/cancel/overwrite) and
  Esc/Ctrl+C abort mid-download on `RANGE.BIN`;
  `2026-09-04_22-19-18 (2).png`, `2026-09-04_22-19-51 (2).png`,
  `2026-09-04_22-20-45 (2).png` — `RANGE.BIN` full resume, `CLOSE.BIN`,
  redirect 302/301, 404, 500.

| Case | Expected | Result/evidence |
|---|---|---|
| Help and invalid URL | exact golden text | Invalid-URL usage path confirmed on-screen (scrolls correctly past the WIN1/WIN2 fix). `WGET /?` itself was run and reported passing, but no screenshot captured its output directly (scrolled above the captured crop) — **not independently verified from an image**, only user-reported. |
| zero/small/large | RESULT OK, byte-exact files | `2026-09-04_21-03-59`/`21-05-18`; files byte-exact vs fixtures (re-verified 2026-09-04 after Session B: `ZERO.BIN`, `SMALL.BIN`, `LARGE.BIN` all `cmp`-clean). |
| segmented headers/body | byte-exact file | Covered by the 53-scenario actual-EXE harness suite (`node tools/test-stage12-exe.js`), not re-derived from this MAME run. |
| close-delimited | RESULT OK | `2026-09-04_22-19-18`; `CLOSE.BIN` byte-exact vs fixture. |
| redirect path/absolute | final body only | `2026-09-04_22-19-18`/`22-19-51`/`22-20-45`: `Redirect: HTTP/1.0 302 Found` and `301 Moved Permanently`; `REDIR.BIN`/`ABS.BIN` both byte-exact against the final resource only (no redirect body). |
| 404/500 | RESULT FAIL, no error file | `2026-09-04_22-20-45`: `[E] HTTP/1.0 404 Not Found` / `500 Internal Server Error`, `RESULT FAIL`; `ERR404.BIN`/`ERR500.BIN` confirmed absent from the FAT12 directory. |
| prompt O/R/C | exact prompt, echo and cancel | `2026-09-04_21-33-26`: `Local file 'RANGE.BIN' exists. Overwrite/Resume/Cancel [O/R/C]?` answered `r`, `c` (`Aborted by user.`), `o` in sequence. |
| Range ignored | original file unchanged | Not separately exercised this session (no server that ignores Range was targeted); covered by the harness fault-injection suite only. |
| full resume | Range 206, full checksum | `2026-09-04_21-33-26` (`r` → 4465-byte tail, `Done.`) and `2026-09-04_22-19-18` (repeat after the Esc abort below); `RANGE.BIN` re-verified byte-exact (70001 bytes) against the full fixture after both sessions. |
| Esc/Ctrl+C | partial retained, returns to DSS | `2026-09-04_21-33-26`: aborted at `5KB/68KB`, `Aborted by user (Esc/Ctrl+C).`, `RESULT FAIL`, DSS prompt returned without hanging. |

Fixture and extracted-file SHA-256 (re-verified 2026-09-04, after both sessions,
against `build/stage12-mame/extracted/*` pulled fresh from the final image):

```text
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ZERO.BIN
62de44205d5a14ca883460f18f19cb6e0968279a7967ad4ef432193629a5fda0  SMALL.BIN
7caed97a4d7f1e7e7be8767bc9437e6c77122bc9306517ff2f672e6de941f315  LARGE.BIN
7caed97a4d7f1e7e7be8767bc9437e6c77122bc9306517ff2f672e6de941f315  RANGE.BIN
62de44205d5a14ca883460f18f19cb6e0968279a7967ad4ef432193629a5fda0  CLOSE.BIN
62de44205d5a14ca883460f18f19cb6e0968279a7967ad4ef432193629a5fda0  REDIR.BIN
62de44205d5a14ca883460f18f19cb6e0968279a7967ad4ef432193629a5fda0  ABS.BIN
897f0719fbd1a503180abb6cbf1fd692ce429130ac4fcc78f3e7dfdf310aa310  WGET.EXE
```

All eight match their fixture/build counterpart (`cmp`-clean); `LARGE.BIN` and
`RANGE.BIN` share content and hash by construction (same 70001-byte fixture
body), as do `SMALL.BIN`/`CLOSE.BIN`/`REDIR.BIN`/`ABS.BIN` (same 1537-byte body).

Result: `PASS`, with two caveats carried forward rather than silently closed:
evidence spans two responder sessions instead of one continuous capture (see
above), and `WGET /?`'s exact golden text was not independently confirmed from
a screenshot. Neither reflects a functional defect found during this gate.
This record does not replace the physical Sprinter gate.
