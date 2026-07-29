#!/usr/bin/env bash
# Tails a cloudflared quick-tunnel log for the assigned trycloudflare.com URL
# and re-emits it as a stable, greppable sentinel line, e.g.:
#   SIDEKICK_TUNNEL_URL=https://xxxx.trycloudflare.com
#
# Parameterized so one script serves both tunnels (the control tunnel and the
# public webapp tunnel):
#   SIDEKICK_CLOUDFLARED_LOG  which cloudflared log to watch
#   SIDEKICK_URL_SENTINEL     sentinel name to emit (default SIDEKICK_TUNNEL_URL)
#   SIDEKICK_RENDEZVOUS_FIELD JSON field to report over the rendezvous (default base_url)
#
# The sentinel is written to stdout (so `docker logs` / `fly logs` see it for
# the containerized deploy path) AND to /dev/console when present (so EC2's
# `get-console-output` / a serial console see it for the bare-VM path).
set -euo pipefail

LOGFILE="${SIDEKICK_CLOUDFLARED_LOG:-/var/log/sidekick/cloudflared.log}"
SENTINEL="${SIDEKICK_URL_SENTINEL:-SIDEKICK_TUNNEL_URL}"
RV_FIELD="${SIDEKICK_RENDEZVOUS_FIELD:-base_url}"
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"

last_url=""

# When the installer deployed us via a platform that can't scrape our logs
# (Hetzner), it hands us a return-path rendezvous URL + secret. On the first
# URL we see, POST it back (under RV_FIELD) so the installer learns where we
# are. Retried a few times in case the installer's receiver isn't up yet. The
# receiver accumulates fields, so the two watchers report independently.
report_rendezvous() {
  local url="$1"
  [ -n "${SIDEKICK_RENDEZVOUS_URL:-}" ] || return 0
  local body attempt
  body="{\"server_id\":\"${SERVER_ID:-}\",\"${RV_FIELD}\":\"${url}\"}"
  for attempt in 1 2 3 4 5 6; do
    if curl -fsS -m 10 -X POST "${SIDEKICK_RENDEZVOUS_URL%/}/report" \
        -H "X-Sidekick-Rendezvous: ${SIDEKICK_RENDEZVOUS_SECRET:-}" \
        -H "Content-Type: application/json" -d "$body" >/dev/null 2>&1; then
      echo "reported ${RV_FIELD} to rendezvous"
      return 0
    fi
    sleep 5
  done
  echo "warning: could not reach rendezvous URL after retries" >&2
}

announce() {
  local url="$1"
  local line="${SENTINEL}=${url}"
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
