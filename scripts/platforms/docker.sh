#!/usr/bin/env bash
# Optional convenience platform: run the sidekick image on any Docker host
# you already have. Uses the local Docker socket by default; set DOCKER_HOST
# yourself (tcp://... with TLS) to target a remote host. Never uses ssh://.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"

IMAGE="${SIDEKICK_IMAGE:-ghcr.io/eladb/sidekick:latest}"
CONTAINER_NAME="${SIDEKICK_CONTAINER_NAME:-sidekick}"
BUILD_LOCAL="${SIDEKICK_BUILD_LOCAL:-false}"

if ! docker version >/dev/null 2>&1; then
  echo "error: no reachable Docker daemon (checked \$DOCKER_HOST / local socket)." >&2
  echo "Either start Docker locally, or set DOCKER_HOST to a reachable remote host." >&2
  exit 1
fi

if [ "$BUILD_LOCAL" = "true" ]; then
  echo "==> building image locally"
  docker build -t sidekick:local "$SCRIPT_DIR/../.."
  IMAGE="sidekick:local"
else
  echo "==> pulling $IMAGE"
  docker pull "$IMAGE"
fi

echo "==> starting container $CONTAINER_NAME"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -e AUTH_TOKEN="$AUTH_TOKEN" \
  -e SERVER_ID="$SERVER_ID" \
  -e SIDEKICK_INIT=container \
  "$IMAGE" >/dev/null

echo "==> waiting for tunnel URL"
BASE_URL="$(sidekick_wait_for_tunnel_url "docker logs $CONTAINER_NAME" 180)" || {
  echo "error: timed out waiting for the tunnel URL. Check: docker logs $CONTAINER_NAME" >&2
  exit 1
}

WEBAPP_URL="$(sidekick_wait_for_tunnel_url "docker logs $CONTAINER_NAME" 120 SIDEKICK_WEBAPP_URL || true)"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "docker" "$CREATED_AT" "$WEBAPP_URL")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}" "$WEBAPP_URL"
