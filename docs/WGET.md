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

Normal progress is repainted after the first and every fourth 8 KiB flush, then
once at completion. `-d` prints one dot per 8 KiB flush instead of the KB
counter; the final time/rate summary is still printed. Content without a
`Content-Length` is read until the peer closes. Esc or Ctrl+C, timeout, and a
premature close retain already received bytes for a later `-r` run.

Exit classes are: 0 success, 1 arguments, 2 hardware, 3 network/timeout,
4 configuration, 5 local file error, 6 HTTP/server error, and 7 cancellation.
