# WGET

`WGET.EXE` downloads plain HTTP/1.0 resources through the polling-only 3C509B
backend. HTTPS/TLS is not supported.

```text
WGET url [-o output] [-y|-f] [-r] [-d]
WGET /?
```

The URL must begin with `http://` (case-insensitive). Port 80 and path `/` are
the defaults. Without `-o`, WGET uses the URL basename; an empty basename
becomes `OUTPUT.BIN`. Options may use `-` or `/`, are case-insensitive, and may
appear in any order.

If the output exists, WGET asks whether to overwrite, resume, or cancel.
`-y`/`-f` overwrites without asking. `-r` silently resumes and takes precedence
over overwrite flags: the local size is obtained with DSS `MOVE_FP`, the GET
contains `Range: bytes=N-`, and no bytes are appended unless the server replies
with `206 Partial Content`.

WGET follows at most five absolute `http://` or path-only redirects. An HTTPS,
missing, or malformed `Location` fails without writing the response body.
HTTP error pages are not stored. A new empty output is removed after an HTTP
failure; a pre-existing resume file is retained unchanged.

Normal progress is repainted every sixteenth disk-buffer flush — the body
is received one segment at a time straight into the buffer and whole 512-byte
sectors are written as soon as the next segment would not fit, so a flush is
about one segment and the repaint interval roughly 20 KiB — and once more at
completion. Repainting on every flush cost measurable transfer time: the
counter is a carriage return, a dozen console characters and two 32-bit
decimal conversions, all of it on the download's critical path. `-d` prints one dot per flush instead of the KB
counter; the final time/rate summary is still printed. Esc or Ctrl+C, timeout, and a premature
close retain already received bytes for a later `-r` run.

A response carrying `Content-Length` is finished the moment that many body
bytes have arrived: the request asks for `Connection: close`, but a server is
free to ignore that and hold the socket open, as HTTP/1.1 servers do by
default, so waiting for a close would stall a download that already completed.
Content without a `Content-Length` is read until the peer closes, which is the
only end-of-body marker such a response has. A connection that closes before a
declared `Content-Length` is reached is reported as a truncated transfer.

Exit classes are: 0 success, 1 arguments, 2 hardware, 3 network/timeout,
4 configuration, 5 local file error, 6 HTTP/server error, and 7 cancellation.
