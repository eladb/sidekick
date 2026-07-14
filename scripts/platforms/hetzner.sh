#!/usr/bin/env bash
# Hetzner Cloud, no SSH: cloud-init user-data does all setup, same as ec2.sh
# (bare-VM/systemd mode, no Docker on the box, no SSH key attached — nothing
# needs to log into this box). The tunnel URL is scraped from Hetzner's
# serial console API (a WSS text stream, not SSH) via `hcloud server
# request-console` + a short-lived `websocat` read.
#
# Note: unlike EC2's get-console-output, Hetzner's console API has not been
# exercised end-to-end in this environment (no Hetzner credentials
# available here) — if the scrape times out, the printed fallback command
# lets you check the console manually in the Hetzner Cloud dashboard.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"

command -v hcloud >/dev/null 2>&1 || {
  echo "error: hcloud CLI not found. Install it: https://github.com/hetznercloud/cli" >&2
  exit 1
}
command -v websocat >/dev/null 2>&1 || {
  echo "error: websocat not found (needed to read Hetzner's serial console). Install it: https://github.com/vi/websocat" >&2
  exit 1
}

SERVER_TYPE="${SIDEKICK_HETZNER_TYPE:-cpx22}"
LOCATION="${SIDEKICK_HETZNER_LOCATION:-nbg1}"
REPO="${SIDEKICK_REPO:-eladb/sidekick}"
REPO_REF="${SIDEKICK_REPO_REF:-main}"
SERVER_NAME="sidekick-${SERVER_ID}"

USER_DATA_FILE="$(mktemp)"
trap 'rm -f "$USER_DATA_FILE"' EXIT
SIDEKICK_ENV="AUTH_TOKEN=${AUTH_TOKEN} SERVER_ID=${SERVER_ID}"
cat > "$USER_DATA_FILE" <<EOF
#cloud-config
# Each runcmd entry is its own shell invocation (cloud-init does not persist
# exports between them), so the env vars are passed inline on the two
# commands that actually need them.
runcmd:
  - mkdir -p /opt/sidekick-src
  - curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${REPO_REF}.tar.gz" | tar xz -C /opt/sidekick-src --strip-components=1
  - chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh
  - ${SIDEKICK_ENV} /opt/sidekick-src/provision.sh
  - ${SIDEKICK_ENV} /opt/sidekick-src/configure-and-start.sh
EOF

echo "==> creating server $SERVER_NAME ($SERVER_TYPE, $LOCATION) with no SSH key"
hcloud server create --name "$SERVER_NAME" --type "$SERVER_TYPE" --image debian-12 \
  --location "$LOCATION" --user-data-from-file "$USER_DATA_FILE" >/dev/null

fetch_console_log() {
  local console_json wss_url
  console_json="$(hcloud server request-console "$SERVER_NAME" -o json 2>/dev/null)" || return 0
  wss_url="$(echo "$console_json" | grep -oE '"wss_url":"[^"]+"' | cut -d'"' -f4)"
  [ -n "$wss_url" ] || return 0
  timeout 8 websocat -B 1000000 "$wss_url" 2>/dev/null || true
}

echo "==> waiting for tunnel URL via Hetzner serial console"
BASE_URL="$(sidekick_wait_for_tunnel_url "fetch_console_log" 300)" || {
  echo "error: timed out waiting for the tunnel URL via the console API." >&2
  echo "Check manually: hcloud server request-console $SERVER_NAME  (open the wss_url in the Hetzner dashboard's console viewer instead)" >&2
  exit 1
}

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "hetzner" "$CREATED_AT")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}"
