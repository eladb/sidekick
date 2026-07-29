#!/usr/bin/env bash
# Installer-side rendezvous: for platforms where the installer can't read the
# box's logs to scrape its tunnel URL (Hetzner exposes only a graphical VNC
# console, no text console API), the box instead PUSHES its URL back to us.
#
# We run a tiny local receiver behind our OWN ephemeral cloudflared quick
# tunnel and hand the box that receiver URL (+ a shared secret) via cloud-init.
# When the box's own tunnel comes up, its tunnel-watcher POSTs the URL here.
#
# Requires `cloudflared` and `python3` on the machine running the installer,
# and outbound reach to Cloudflare's edge (TCP/UDP 7844). Sourced, not run.

SIDEKICK_RV_URL=""
SIDEKICK_RV_SECRET=""
_RV_RECEIVER_PID=""
_RV_TUNNEL_PID=""
_RV_TMPDIR=""

# Starts the receiver + ephemeral tunnel. On success sets SIDEKICK_RV_URL and
# SIDEKICK_RV_SECRET. Returns non-zero (with a clear message) if the tooling is
# missing or cloudflared can't register with the edge.
sidekick_rendezvous_start() {
  local script_dir="$1" timeout_sec="${2:-40}"
  command -v cloudflared >/dev/null 2>&1 || {
    echo "error: cloudflared not found. The Hetzner installer needs it to run a" >&2
    echo "       return-path tunnel for URL discovery. Install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 not found (needed for the rendezvous receiver)." >&2
    return 1
  }

  _RV_TMPDIR="$(mktemp -d)"
  SIDEKICK_RV_SECRET="$(sidekick_gen_secret)"
  local port cf_log result_file
  cf_log="$_RV_TMPDIR/cloudflared.log"
  result_file="$_RV_TMPDIR/base_url"
  # Pick an ephemeral local port the receiver and tunnel agree on.
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  export SIDEKICK_RV_RESULT_FILE="$result_file"

  python3 "$script_dir/lib/rendezvous_receiver.py" "$port" "$SIDEKICK_RV_SECRET" "$result_file" &
  _RV_RECEIVER_PID=$!

  cloudflared tunnel --url "http://localhost:$port" --no-autoupdate --logfile "$cf_log" >/dev/null 2>&1 &
  _RV_TUNNEL_PID=$!

  echo "==> starting return-path rendezvous tunnel" >&2
  local waited=0 url="" registered=""
  while [ "$waited" -lt "$timeout_sec" ]; do
    if ! kill -0 "$_RV_TUNNEL_PID" 2>/dev/null; then
      echo "error: cloudflared exited before the rendezvous tunnel came up." >&2
      sidekick_rendezvous_cleanup
      return 1
    fi
    [ -z "$url" ] && url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$cf_log" 2>/dev/null | head -1 || true)"
    registered="$(grep -oE 'Registered tunnel connection|Connection [a-f0-9-]+ registered' "$cf_log" 2>/dev/null | head -1 || true)"
    if [ -n "$url" ] && [ -n "$registered" ]; then
      SIDEKICK_RV_URL="$url"
      echo "    rendezvous ready at $url" >&2
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  echo "error: the rendezvous tunnel did not register with Cloudflare's edge in ${timeout_sec}s." >&2
  echo "       This usually means outbound access to Cloudflare (port 7844) is blocked" >&2
  echo "       from where you're running the installer. Run it from a less restricted" >&2
  echo "       network, or deploy Hetzner from a host with open egress." >&2
  sidekick_rendezvous_cleanup
  return 1
}

# Waits for the box to report its control URL; echoes base_url on stdout.
sidekick_rendezvous_wait() {
  local timeout_sec="${1:-300}" waited=0
  while [ "$waited" -lt "$timeout_sec" ]; do
    if [ -s "$SIDEKICK_RV_RESULT_FILE" ]; then
      cat "$SIDEKICK_RV_RESULT_FILE"
      return 0
    fi
    echo "  ... waiting for the box to report its URL (${waited}s/${timeout_sec}s)" >&2
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# Best-effort: echoes the public webapp URL if the box reported one, else empty.
# The webapp tunnel usually registers a few seconds behind the control tunnel.
sidekick_rendezvous_webapp_url() {
  local timeout_sec="${1:-60}" waited=0 f="${SIDEKICK_RV_RESULT_FILE}.webapp"
  while [ "$waited" -lt "$timeout_sec" ]; do
    [ -s "$f" ] && { cat "$f"; return 0; }
    sleep 5
    waited=$((waited + 5))
  done
  return 0
}

sidekick_rendezvous_cleanup() {
  [ -n "$_RV_RECEIVER_PID" ] && kill "$_RV_RECEIVER_PID" 2>/dev/null || true
  [ -n "$_RV_TUNNEL_PID" ] && kill "$_RV_TUNNEL_PID" 2>/dev/null || true
  [ -n "$_RV_TMPDIR" ] && rm -rf "$_RV_TMPDIR" 2>/dev/null || true
}
