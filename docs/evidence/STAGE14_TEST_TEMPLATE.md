# Stage 14 MAME acceptance — YYYY-MM-DD

- Result: PASS / FAIL
- Environment: Sprinter MAME, responder host IP 192.168.7.44 on feth1, Sprinter 192.168.7.21
- Image: `build/stage14-mame/stage14-unet.img`
- Screenshots: ____________________

## DSS results

- Scenario 0: `UNETTEST /?` usage text and `-d MISSING.DLL` load failure,
  both before any ISA access: ____________________
- Scenario A: plain `UNETTEST 192.168.7.44 8080` against `tcp-echo`;
  `caps=0x023F abi=0x0100`, NETINIT ok, connect, request sent, echoed reply,
  closed, `RESULT OK`: ____________________
- Scenario B: `UNETTEST 192.168.7.44 8081` against `tcp-refuse`; `failed`,
  `lasterr:` line, `RESULT FAIL`: ____________________
- Scenario C: `UNETTEST -u 7777` / `-u 7777 1472` / `-u 7777 1473` against
  `udp-echo`; first two `RESULT OK` byte-exact echo, third `NERR_PARAM` and
  zero datagrams on the wire: ____________________
- Scenario D: `UNETTEST -2 9100 192.168.7.44 9099` against `dual`; both
  channels connect, sequence check reports OK, non-zero bytes received,
  `RESULT OK`: ____________________
- Scenario E: `UNETTEST -l 9000` against `listen-client` (default 2
  attempts); `peer accepted` twice, `unlisten done`, `RESULT OK` --
  confirms CLOSE re-arms LISTEN on the same port: ____________________
- Scenario F: `UNETTEST -a 192.168.7.44 8080` against `tcp-stall`
  (`doautorcvbuf=0` confirmed, no auto-tuning warning in the responder log);
  `resumes needed: N` with N >= 1, `RESULT OK`: ____________________
- Optimized DLL RX: Stage 13's release/fast DLSPEED matrix, five alternating
  successful runs per executable and image, thresholds/window/ACK/checksum
  evidence from `docs/DLSPEED.md`: ____________________

## Real Sprinter

- Scenarios A, C, D, E, F repeated against a real host on the card's actual
  segment (record the substituted addresses and `NET.CFG`): ____________________
- Card/slot/base and MAC observed: ____________________

## Responder logs and hashes

```text
____________________  build/stage14-mame/stage14-unet.img
____________________  build/UNET509B.DLL
____________________  build/UNETTEST.EXE
```

Attach `stage14_responder.py` console output (or a saved log, if redirected)
for each scenario A-F.

## Notes

- `UNETTEST`'s `-a` scenario is only meaningful with TCP receive-buffer
  auto-tuning disabled on the responder host (see
  `docs/STAGE14_TESTING_RU.md`); a run with the auto-tuning warning present
  in the log proves nothing and must be redone, not recorded as a caveat.
- Carry forward any caveat that isn't independently confirmed from a
  screenshot or log, rather than silently closing it.
