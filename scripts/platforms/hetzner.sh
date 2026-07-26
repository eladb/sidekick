#!/usr/bin/env bash
# Hetzner Cloud, no SSH: cloud-init user-data does all setup (bare-VM/systemd
# mode, no Docker on the box, no SSH key attached).
#
# Unlike Docker/fly/EC2, Hetzner exposes only a *graphical* VNC console — there
# is no text console API to scrape the tunnel URL from. So instead the box
# reports its URL back to us over a return-path rendezvous: we run a tiny
# receiver behind our own ephemeral cloudflared tunnel and hand the box that
# URL via cloud-init (see scripts/lib/rendezvous.sh). This needs `cloudflared`
# + `python3` on the installer and outbound reach to Cloudflare's edge.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/rendezvous.sh
source "$SCRIPT_DIR/../lib/rendezvous.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"

command -v hcloud >/dev/null 2>&1 || {
  echo "error: hcloud CLI not found. Install it: https://github.com/hetznercloud/cli" >&2
  exit 1
}

SERVER_TYPE="${SIDEKICK_HETZNER_TYPE:-cpx22}"
LOCATION="${SIDEKICK_HETZNER_LOCATION:-nbg1}"
REPO="${SIDEKICK_REPO:-eladb/sidekick}"
REPO_REF="${SIDEKICK_REPO_REF:-main}"
SERVER_NAME="sidekick-${SERVER_ID}"

# Bring up the return-path rendezvous before creating the server, so its URL
# can be baked into cloud-init. cleanup runs on any exit.
trap 'sidekick_rendezvous_cleanup' EXIT
sidekick_rendezvous_start "$SCRIPT_DIR/.." || exit 1

USER_DATA_FILE="$(mktemp)"
trap 'rm -f "$USER_DATA_FILE"; sidekick_rendezvous_cleanup' EXIT
# provision.sh needs only AUTH_TOKEN/SERVER_ID; configure-and-start.sh also
# needs the rendezvous vars so the box knows where to report its URL.
PROVISION_ENV="AUTH_TOKEN=${AUTH_TOKEN} SERVER_ID=${SERVER_ID}"
CONFIGURE_ENV="${PROVISION_ENV} SIDEKICK_RENDEZVOUS_URL=${SIDEKICK_RV_URL} SIDEKICK_RENDEZVOUS_SECRET=${SIDEKICK_RV_SECRET}"
cat > "$USER_DATA_FILE" <<EOF
#cloud-config
# Each runcmd entry is its own shell invocation (cloud-init does not persist
# exports between them), so the env vars are passed inline on the two commands
# that actually need them.
runcmd:
  - mkdir -p /opt/sidekick-src
  - curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${REPO_REF}.tar.gz" | tar xz -C /opt/sidekick-src --strip-components=1
  - chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh
  - ${PROVISION_ENV} /opt/sidekick-src/provision.sh
  - ${CONFIGURE_ENV} /opt/sidekick-src/configure-and-start.sh
EOF

echo "==> creating server $SERVER_NAME ($SERVER_TYPE, $LOCATION) with no SSH key"
hcloud server create --name "$SERVER_NAME" --type "$SERVER_TYPE" --image debian-12 \
  --location "$LOCATION" --user-data-from-file "$USER_DATA_FILE" >/dev/null

echo "==> waiting for the box to report its tunnel URL"
BASE_URL="$(sidekick_rendezvous_wait 360)" || {
  echo "error: the box never reported its tunnel URL within the timeout." >&2
  echo "The server was created ($SERVER_NAME); check it in the Hetzner dashboard." >&2
  exit 1
}

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "hetzner" "$CREATED_AT")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}"
