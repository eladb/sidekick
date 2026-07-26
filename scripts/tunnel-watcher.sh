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

# When the installer deployed us via a platform that can't scrape our logs
# (Hetzner), it hands us a return-path rendezvous URL + secret. On the first
# tunnel URL we see, POST it back so the installer learns where we are. Retried
# a few times in case the installer's receiver isn't quite up yet.
report_rendezvous() {
  local url="$1"
  [ -n "${SIDEKICK_RENDEZVOUS_URL:-}" ] || return 0
  local body attempt
  body="{\"server_id\":\"${SERVER_ID:-}\",\"base_url\":\"${url}\"}"
  for attempt in 1 2 3 4 5 6; do
    if curl -fsS -m 10 -X POST "${SIDEKICK_RENDEZVOUS_URL%/}/report" \
        -H "X-Sidekick-Rendezvous: ${SIDEKICK_RENDEZVOUS_SECRET:-}" \
        -H "Content-Type: application/json" -d "$body" >/dev/null 2>&1; then
      echo "reported tunnel URL to rendezvous"
      return 0
    fi
    sleep 5
  done
  echo "warning: could not reach rendezvous URL after retries" >&2
}

announce() {
  local url="$1"
  local line="SIDEKICK_TUNNEL_URL=${url}"
  echo "$line"
  if [ -w /dev/console ]; then
    echo "$line" > /dev/console 2>/dev/null || true
  fi
  report_rendezvous "$url"
}

tail -F -n0 "$LOGFILE" 2>/dev/null | while IFS= read -r line; do
  url="$(echo "$line" | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' || true)"
  if [ -n "$url" ] && [ "$url" != "$last_url" ]; then
    last_url="$url"
    announce "$url"
  fi
done
