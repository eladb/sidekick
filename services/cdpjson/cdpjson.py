#!/usr/bin/env python3
"""Minimal stdlib-only HTTP shim in front of Chrome's DevTools JSON endpoints
(/json, /json/version, /json/list, ...).

Why this exists: Chrome's DevTools HTTP endpoints reject any request whose Host
header is not localhost or an IP (returning HTTP 500, "Host header is specified
and is not an IP address or localhost"). Behind the Cloudflare tunnel the Host
is the public trycloudflare hostname, so a direct reverse_proxy to :9222 fails
the CDP handshake. Forcing Host: localhost upstream fixes that 500 — but then
Chrome reports `webSocketDebuggerUrl: ws://localhost/devtools/browser/<id>`,
which CDP clients (e.g. Playwright's connectOverCDP) follow verbatim and cannot
reach.

This shim fetches from Chrome with Host: localhost, then rewrites the reported
ws:// URLs to wss://<public-host> (taken from the incoming request), so the
documented `chromium.connectOverCDP(cdp_url)` flow works through the tunnel.

Binds to 127.0.0.1 only; Caddy is the only thing that should ever reach it, and
Caddy enforces basic_auth on /json* before proxying here (same trust model as
the noVNC/ttyd backends).
"""
import http.client
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SIDEKICK_CDPJSON_PORT", "9223"))
UPSTREAM_PORT = int(os.environ.get("SIDEKICK_CDP_UPSTREAM_PORT", "9222"))
UPSTREAM_HOST = "127.0.0.1"

# ws://<host>  (host runs until the path/quote) -> rewritten to wss://<public>
_WS_HOST_RE = re.compile(rb'wss?://[^"/\\]+')
# devtoolsFrontendUrl carries the ws endpoint as a bare `ws=<host>/...` param.
_WS_PARAM_RE = re.compile(rb'([?&]ws=)[^"&/]+')


def rewrite(body, public_host):
    host = public_host.encode("utf-8")
    body = _WS_HOST_RE.sub(b"wss://" + host, body)
    body = _WS_PARAM_RE.sub(rb"\1" + host, body)
    return body


class Handler(BaseHTTPRequestHandler):
    server_version = "sidekick-cdpjson/1.0"

    def log_message(self, fmt, *args):
        pass  # supervisord captures stdout/stderr; keep it quiet

    def do_GET(self):
        # Public host the client actually connected to (Caddy preserves Host).
        public_host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host")
        if not public_host:
            self.send_error(400, "missing Host")
            return
        try:
            conn = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=15)
            # Force Host: localhost so Chrome accepts the DevTools request.
            conn.request("GET", self.path, headers={"Host": "localhost", "Accept": "application/json"})
            resp = conn.getresponse()
            raw = resp.read()
            status = resp.status
            ctype = resp.getheader("Content-Type", "application/json")
            conn.close()
        except Exception:
            self.send_error(502, "cdp upstream unreachable")
            return

        out = rewrite(raw, public_host) if status == 200 else raw
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
