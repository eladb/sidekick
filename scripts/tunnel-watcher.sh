#!/usr/bin/env bash
# Tails cloudflared's log for the quick-tunnel's assigned trycloudflare.com
# URL and re-emits it as a stable, greppable sentinel line:
#   SIDEKICK_TUNNEL_URL=https://xxxx.trycloudflare.com
#
# Written to stdout (so `docker logs` / `fly logs` see it for the
# containerized deploy path) AND to /dev/console when present (so EC2's
# `get-console-output` / Hetzner's serial console API see it for the bare-VM
# path — supervisord's own child stdout is captured by systemd/journald on a
# bare VM, which does NOT reach the serial console by default, so we write
# there directly instead of relying on journal forwarding).
set -euo pipefail

LOGFILE="${SIDEKICK_CLOUDFLARED_LOG:-/var/log/sidekick/cloudflared.log}"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

last_url=""

announce() {
  local url="$1"
  local line="SIDEKICK_TUNNEL_URL=${url}"
  echo "$line"
  if [ -w /dev/console ]; then
    echo "$line" > /dev/console 2>/dev/null || true
  fi
}

tail -F -n0 "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
  url="$(echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' || true)"
  if [ -n "$url" ] && [ "$url" != "$last_url" ]; then
    last_url="$url"
    announce "$url"
  fi
done
