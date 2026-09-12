# FTP

`FTP.EXE` is a PASV-only FTP client over the polling-only 3C509B backend. The
control and data sessions are two independent TCP channels, opened and read
concurrently — no PORT/active mode, no proxying through a single channel.

```text
FTP host[:port] path [-u user] [-p pass] [-o out] [-y|-f] [-r] [-d]
FTP host[:port] PUT local [-u user] [-p pass] [-o remote]
FTP host[:port] [path] -l|-n [-u user] [-p pass]
FTP /?
```

Port defaults to 21. `-u`/`-p` log in as that user/password; without either,
the client logs in as `anonymous`/`anonymous@` (the conventional anonymous-FTP
password). Giving `-u` without `-p` sends an empty password instead of
`anonymous@`, since that default would be wrong for a real account.

Without `PUT`, `path` is the remote file to download; the local name is its
basename unless `-o` overrides it. With `PUT local`, `local` is read from disk
and the wire-side name is its basename unless `-o` overrides it. In listing
mode (`-l` or `-n`), `path` is optional and names a remote directory; omitted,
the server's own current directory is listed. `-n` behaves exactly like `-l`
in this build — see "Known limitations" below.

If the local output exists, FTP asks whether to overwrite, resume, or cancel,
the same Overwrite/Resume/Cancel contract as WGET. `-y`/`-f` overwrites
without asking; `-r` silently resumes: the local size becomes both a `REST`
offset sent to the server and the starting point of the on-screen byte count.
A server that refuses `REST` fails without downloading anything. `PUT` never
resumes.

Progress repaints every sixteenth disk-buffer flush (`GET`) or upload
chunk (`PUT`) — roughly every 20–32 KiB — and once more when the transfer
ends, so the last figure shown is always exact. Repainting on every flush
cost measurable transfer time: the counter is a carriage return, a dozen
console characters and two 32-bit decimal conversions, all on the transfer's
critical path. `GET` receives each segment straight from the card into its
disk buffer and writes whole 512-byte sectors as soon as the next segment
would not fit, so a flush happens about once per segment and every write is
sector-aligned. `-l`/`-n` streams the listing straight to the console instead.
`-d` prints one dot per flush instead of the KB counter. Esc or Ctrl+C keeps
whatever `GET` has already written, so a later `-r` run continues it; `PUT`
and listings have nothing to preserve on cancel.

A missing or timed-out `226 Transfer complete` after the data channel closes
is not fatal — the transfer already succeeded once the server accepted
`RETR`/`STOR`/`LIST` and the data channel closed cleanly.

Exit classes match WGET: 0 success, 1 arguments, 2 hardware, 3 network/timeout,
4 configuration, 5 local file error, 6 FTP/server error, and 7 cancellation.

## Known limitations

- **No NLST fallback.** The sibling RTL8019A kit's FTP client sends `NLST`
  for `-n` and falls back to `LIST` on a 5xx reply. This build always sends
  `LIST` for both `-l` and `-n` — the fallback logic and the separate `NLST`
  command didn't fit the 16256-byte image-size ceiling alongside everything
  else PASV FTP needs. Functionally this only affects directory listing
  *format* on servers that distinguish the two; the file itself transfers
  identically either way.
- **Shorter messages than the sibling.** The dialog and exit codes match the
  RTL8019A kit's client, but the wording is trimmed (`Host X -> Y`,
  `Opening data...`, `Done. N bytes recv.`) — the full-length strings did not
  fit under the image-size ceiling. `tools/test-fixtures/stage13-ftp-golden.json`
  pins the exact transcripts.
- **`PUT` keeps two segments in flight, not more.** A pair is what obliges the
  receiver to acknowledge at once instead of holding its delayed-ACK timer,
  which is what made uploads slow when only one segment was ever outstanding.
  A deeper window would have to hold several unacknowledged payloads and
  handle partial acknowledgements, and the image-size ceiling has no room for
  that. A tail shorter than two whole segments, and a peer window that cannot
  hold two, still go one segment at a time — see `specs.md`.
