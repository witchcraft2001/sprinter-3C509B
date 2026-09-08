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

Progress repaints after every 4 KiB disk-buffer flush (`GET`) or upload chunk
(`PUT`); `-l`/`-n` streams the listing straight to the console instead.
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
- **`PUT` is stop-and-wait.** `SEND` on this backend keeps at most one MSS in
  flight per call, so uploads do not benefit from the same deep receive
  window that makes `GET` fast. This is a known, documented limitation, not a
  bug — see `specs.md`.
