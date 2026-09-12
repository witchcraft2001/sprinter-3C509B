# Stage 13 MAME acceptance — YYYY-MM-DD

- Result: PASS / FAIL
- Environment: Sprinter MAME, responder interface, MAME interface
- Image: `build/stage13-mame/stage13-ftp.img`
- Responder profile: clean / faults
- Pcap: `evidence/stage13/stage13-PROFILE.pcap`
- Screenshots: ____________________

## DSS results

- `FTP /?` and invalid-argument usage text: ____________________
- Anonymous GET, small and large fixture, byte-exact: ____________________
- `-u`/`-p` explicit login: ____________________
- `-l`/`-n` directory listing to console: ____________________
- `-o` local/remote rename (GET and PUT): ____________________
- REST resume on a partial local file, byte-exact after, with no duplicated
  prefix (responder now actually honors the offset instead of resending the
  whole fixture): ____________________
- REST refused by server: no partial corruption, `RESULT FAIL`: ____________________
- `PUT`, uploaded bytes byte-exact against local fixture: ____________________
- Overwrite/Resume/Cancel prompt (no `-y`/`-r`): ____________________
- Esc/Ctrl+C mid-`GET`: partial retained, resumable with `-r`: ____________________
- 530 login refusal (responder restarted with `--profile refuse-pass` --
  the default `clean` profile accepts any password, so this step fails to
  demonstrate anything under `clean`): ____________________
- 550 RETR/STOR/SIZE refusal: ____________________
- Data-channel abort/RST mid-transfer: bounded exit, no hang: ____________________
- Missing/timed-out `226`: transfer still reports success: ____________________
- `226 Transfer complete.` printed on a *small* GET too (it arrives on the
  control channel while the data channel is still open, and must not be
  dropped): ____________________
- Flag before the positional path (`FTP host -p pass FILE.BIN`) still fetches
  `FILE.BIN`, not the flag's own value: ____________________
- `DLSPEED /?`, `DLDIRECT /?` and invalid-URL usage text: ____________________
- Release image: alternating `DLDIRECT`, `DLSPEED`, `DLSPEED`, `DLDIRECT`
  against the same 4 MiB URL, at least five successful results each;
  median DLDIRECT >= 150 KB/s and DLSPEED/DLDIRECT >= 40%: ____________________
- Non-release fast image: the same alternation and counts; median DLDIRECT
  >= 180 KB/s and DLSPEED >= 76 KB/s: ____________________
- Both images: exact 4194304-byte counts, per-run seconds/KB/s and medians,
  valid outgoing checksums, FIN without RST, and successful repeated launch:
  ____________________

## Pcap checks

- SYN to the control port (21 or configured), `227` PASV reply, SYN to the
  announced data port: ____________________
- Up to 5 segments in flight on the data channel; `win=0` is not repeated for
  every MSS (at most the initial pre-RECV closure): ____________________
- DLL RX: window <= 2680, first direct ACK expands the initial 536-byte
  window, cumulative ACKs cover
  pairs, final ACK returns to durable 536, fewer RECV calls than segments:
  ____________________
- `tools/stage13-mame.sh pcap-check` output: ____________________

## Fixture and extracted-file SHA-256

```text
____________________  SMALL.BIN
____________________  LARGE.BIN
____________________  FTP.EXE
____________________  DLSPEED.EXE
____________________  DLDIRECT.EXE
```

## Notes

- Known, accepted limitations (not defects, do not re-report): `-n` behaves
  identically to `-l` (no NLST fallback, see `docs/FTP.md`); `PUT` is
  stop-and-wait and will not show the same throughput as `GET`; the message
  wording is shorter than the sibling client's.
- Carry forward any caveat that isn't independently confirmed from a
  screenshot or pcap, the way Stage 12's record does, rather than silently
  closing it.
