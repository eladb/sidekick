#!/usr/bin/env python3
"""Minimal stdlib-only HTTP service exposing POST /exec for programmatic
command execution on the sidekick box. Intentionally full shell access,
gated only by HTTP Basic Auth (see check_auth) — the whole point of this
service is to let an agent run commands on its own server. Treat the auth
token like a root password.

Binds to 127.0.0.1 only; Caddy is the only thing that should ever reach it.
"""
import base64
import hmac
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AUTH_TOKEN = os.environ["SIDEKICK_AUTH_TOKEN"]
PORT = int(os.environ.get("SIDEKICK_EXECD_PORT", "8090"))
DEFAULT_TIMEOUT_SEC = 300


def check_auth(header_value):
    if not header_value or not header_value.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(header_value[len("Basic "):]).decode("utf-8")
        _, _, password = decoded.partition(":")
    except Exception:
        return False
    return hmac.compare_digest(password, AUTH_TOKEN)


class Handler(BaseHTTPRequestHandler):
    server_version = "sidekick-execd/1.0"

    def log_message(self, fmt, *args):
        pass  # supervisord already captures stdout/stderr; keep it quiet

    def _send_json_error(self, code, message):
        body = json.dumps({"error": message}).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/exec":
            self._send_json_error(404, "not found")
            return
        if not check_auth(self.headers.get("Authorization")):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="sidekick"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self._send_json_error(400, "invalid JSON body")
            return

        cmd = payload.get("cmd")
        if not cmd or not isinstance(cmd, str):
            self._send_json_error(400, "'cmd' (string) is required")
            return
        cwd = payload.get("cwd") or None
        timeout_sec = payload.get("timeout_sec") or DEFAULT_TIMEOUT_SEC

        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        self._run_streaming(cmd, cwd, timeout_sec)

    def _write_chunk(self, obj):
        data = (json.dumps(obj) + "\n").encode("utf-8")
        self.wfile.write(b"%x\r\n%b\r\n" % (len(data), data))

    def _run_streaming(self, cmd, cwd, timeout_sec):
        # Run through a shell so agents get the semantics they expect from a
        # command string: pipes, &&/||, redirections, globs, env expansion.
        # A list cmd is still honored verbatim (no shell) for callers that
        # want exact argv control.
        proc = subprocess.Popen(
            cmd if isinstance(cmd, list) else ["/bin/bash", "-lc", cmd],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

        def pump(stream, name):
            for line in iter(stream.readline, ""):
                self._write_chunk({"stream": name, "data": line})
            stream.close()

        threads = [
            threading.Thread(target=pump, args=(proc.stdout, "stdout")),
            threading.Thread(target=pump, args=(proc.stderr, "stderr")),
        ]
        for t in threads:
            t.start()

        try:
            exit_code = proc.wait(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            proc.kill()
            exit_code = proc.wait()
            self._write_chunk({"stream": "stderr", "data": "[execd] timed out, process killed\n"})

        for t in threads:
            t.join()

        self._write_chunk({"exit_code": exit_code})
        self.wfile.write(b"0\r\n\r\n")  # terminate chunked response


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
