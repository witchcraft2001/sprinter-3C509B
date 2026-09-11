#!/usr/bin/env python3
"""Deterministic TCP HTTP responder for real Sprinter Stage 13 tests.

Unlike stage13_responder.py this uses the host TCP stack, so it can listen on
an address assigned to a physical Ethernet interface.  It intentionally keeps
the response open after the body, matching the raw MAME responder contract.
"""

import argparse
import hashlib
import http.server
import socketserver
import sys


HTTP_LARGE = bytes((index * 37 + 11) & 0xFF for index in range(4 * 1024 * 1024))


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802 - required by BaseHTTPRequestHandler
        body = HTTP_LARGE
        self.send_response(200, "OK")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        print(f"GET {self.path} bytes={len(body)}", flush=True)

    def log_message(self, fmt, *args):
        print("HTTP " + (fmt % args), flush=True)


class ReusableServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="192.168.7.44",
                        help="local address to publish (default: %(default)s)")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args(argv)
    digest = hashlib.sha256(HTTP_LARGE).hexdigest()
    try:
        with ReusableServer((args.bind, args.port), Handler) as server:
            print(f"READY tcp-http bind={args.bind}:{args.port} "
                  f"bytes={len(HTTP_LARGE)} sha256={digest}", flush=True)
            server.serve_forever()
    except OSError as exc:
        parser.exit(1, f"error: cannot listen on {args.bind}:{args.port}: {exc}\n")
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
