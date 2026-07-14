#!/usr/bin/env bash
# fly.io: already fully HTTPS-API-driven via flyctl, no SSH and no manual
# Docker involved from the caller's side. fly.io's own inbound proxy/ports
# are unused entirely — the box only needs outbound access to reach
# Cloudflare's edge for the tunnel, so no fly "services"/port mapping needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"

command -v flyctl >/dev/null 2>&1 || command -v fly >/dev/null 2>&1 || {
  echo "error: flyctl not found. Install it: https://fly.io/docs/flyctl/install/" >&2
  exit 1
}
FLY="$(command -v flyctl || command -v fly)"

IMAGE="${SIDEKICK_IMAGE:-ghcr.io/eladb/sidekick:latest}"
APP_NAME="${SIDEKICK_FLY_APP:-sidekick-${SERVER_ID}}"
REGION="${SIDEKICK_FLY_REGION:-iad}"
ORG_FLAG=()
[ -n "${SIDEKICK_FLY_ORG:-}" ] && ORG_FLAG=(--org "$SIDEKICK_FLY_ORG")

echo "==> creating fly app $APP_NAME"
"$FLY" apps create "$APP_NAME" "${ORG_FLAG[@]}" >/dev/null

echo "==> launching machine"
"$FLY" machine run "$IMAGE" \
  --app "$APP_NAME" \
  --name sidekick \
  --region "$REGION" \
  -e AUTH_TOKEN="$AUTH_TOKEN" \
  -e SERVER_ID="$SERVER_ID" \
  -e SIDEKICK_INIT=container \
  >/dev/null

echo "==> waiting for tunnel URL"
BASE_URL="$(sidekick_wait_for_tunnel_url "$FLY logs -a $APP_NAME --no-tail" 180)" || {
  echo "error: timed out waiting for the tunnel URL. Check: $FLY logs -a $APP_NAME" >&2
  exit 1
}

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "fly" "$CREATED_AT")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}"
