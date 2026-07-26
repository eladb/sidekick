#!/usr/bin/env python3
"""Installer-side rendezvous receiver.

Listens on 127.0.0.1:<port> behind the installer's own ephemeral cloudflared
tunnel. The freshly-deployed sidekick box POSTs its discovered tunnel URL here
once cloudflared comes up, so the installer learns the URL without SSH, without
scraping a platform console, and without any inbound port of its own.

    POST /report
    Header: X-Sidekick-Rendezvous: <shared secret>
    Body:   {"server_id": "...", "base_url": "https://xxxx.trycloudflare.com"}

On the first authenticated report it writes base_url to <result_file> and keeps
serving (so box-side retries are harmless) until the installer kills it.

Usage: rendezvous_receiver.py <port> <secret> <result_file>
Only the Python 3 standard library is used.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
SECRET = sys.argv[2]
RESULT_FILE = sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass  # stay quiet; the installer prints its own progress

    def _reply(self, code, msg):
        body = (msg + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path.rstrip("/") != "/report":
            return self._reply(404, "not found")
        if self.headers.get("X-Sidekick-Rendezvous", "") != SECRET:
            return self._reply(403, "forbidden")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
            base_url = str(payload.get("base_url", "")).strip()
        except (ValueError, TypeError):
            return self._reply(400, "bad request")
        if not base_url.startswith("https://"):
            return self._reply(400, "missing base_url")
        with open(RESULT_FILE, "w", encoding="utf-8") as fh:
            fh.write(base_url)
        self._reply(200, "ok")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
