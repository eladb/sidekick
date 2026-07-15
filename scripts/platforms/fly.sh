#!/usr/bin/env bash
# fly.io, driven straight through the fly Machines API over HTTPS (needs only
# FLY_API_TOKEN — no flyctl, no SSH, no local Docker, no prebuilt image). Like
# EC2/Hetzner, the box builds itself from source at boot: a stock
# debian:bookworm-slim machine runs provision.sh + configure-and-start.sh
# (container mode) as its init command, so there's nothing to publish to a
# registry — the same clone-and-run flow as every other platform.
#
# fly's own inbound proxy/ports are unused entirely (no fly "services") — the
# box only needs outbound access to reach Cloudflare's edge for the tunnel, and
# we discover the tunnel URL through the Machines API `exec` endpoint (no public
# port, no log-scraping).
#
# Note: the first boot installs Chromium et al. via apt, which on fly's default
# shared CPUs takes ~10-12 min (vs ~4 min on a Hetzner cpx22). Bump
# SIDEKICK_FLY_CPUS for a faster first boot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"
: "${FLY_API_TOKEN:?FLY_API_TOKEN is required (get one with: flyctl tokens create org, or from the fly dashboard)}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required (used to build/parse the fly API JSON)." >&2; exit 1; }

BASE_IMAGE="${SIDEKICK_FLY_BASE_IMAGE:-docker.io/library/debian:bookworm-slim}"
APP_NAME="${SIDEKICK_FLY_APP:-sidekick-${SERVER_ID}}"
REGION="${SIDEKICK_FLY_REGION:-iad}"
ORG="${SIDEKICK_FLY_ORG:-personal}"
CPUS="${SIDEKICK_FLY_CPUS:-2}"
MEMORY="${SIDEKICK_FLY_MEMORY:-2048}"
REPO="${SIDEKICK_REPO:-eladb/sidekick}"
REPO_REF="${SIDEKICK_REPO_REF:-main}"
API="https://api.machines.dev/v1"
AUTH_HDR="Authorization: Bearer ${FLY_API_TOKEN}"

# Boot command: fetch source, provision, then exec the service manager. Env
# (AUTH_TOKEN/SERVER_ID/SIDEKICK_INIT) is injected via the machine config, so
# the box reads it straight from the environment — same contract as cloud-init.
BOOT="set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates tar
mkdir -p /opt/sidekick-src
curl -fsSL \"https://github.com/${REPO}/archive/refs/heads/${REPO_REF}.tar.gz\" | tar xz -C /opt/sidekick-src --strip-components=1
chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh
/opt/sidekick-src/provision.sh
exec /opt/sidekick-src/configure-and-start.sh"

echo "==> creating fly app $APP_NAME (org: $ORG)"
create_app="$(curl -fsS -X POST "$API/apps" -H "$AUTH_HDR" -H 'Content-Type: application/json' \
  -d "{\"app_name\":\"${APP_NAME}\",\"org_slug\":\"${ORG}\"}" 2>&1)" || {
  echo "error: failed to create app: $create_app" >&2; exit 1; }

# Build the machine config JSON with python3 so the multi-line boot script is
# escaped correctly, then create the machine.
MACHINE_CFG="$(BOOT="$BOOT" AUTH_TOKEN="$AUTH_TOKEN" SERVER_ID="$SERVER_ID" \
  REGION="$REGION" CPUS="$CPUS" MEMORY="$MEMORY" BASE_IMAGE="$BASE_IMAGE" python3 -c '
import json, os
print(json.dumps({
  "region": os.environ["REGION"],
  "config": {
    "image": os.environ["BASE_IMAGE"],
    "env": {"AUTH_TOKEN": os.environ["AUTH_TOKEN"], "SERVER_ID": os.environ["SERVER_ID"], "SIDEKICK_INIT": "container"},
    "init": {"exec": ["/bin/bash", "-lc", os.environ["BOOT"]]},
    "guest": {"cpu_kind": "shared", "cpus": int(os.environ["CPUS"]), "memory_mb": int(os.environ["MEMORY"])},
    "auto_destroy": False,
    "restart": {"policy": "on-failure", "max_retries": 3},
  },
}))')"

echo "==> launching machine ($BASE_IMAGE, ${CPUS} cpu / ${MEMORY}MB; first boot installs everything, ~10-12 min)"
MID="$(curl -fsS -X POST "$API/apps/${APP_NAME}/machines" -H "$AUTH_HDR" -H 'Content-Type: application/json' \
  -d "$MACHINE_CFG" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" || {
  echo "error: failed to create machine." >&2; exit 1; }
echo "    machine $MID"

# Run a command inside the machine via the Machines API exec endpoint.
fly_exec() {
  curl -fsS -X POST "$API/apps/${APP_NAME}/machines/${MID}/exec" -H "$AUTH_HDR" -H 'Content-Type: application/json' \
    -d "{\"command\":[\"/bin/sh\",\"-c\",$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")],\"timeout\":55}" 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("stdout",""), end="")
except Exception: pass'
}

echo "==> waiting for the server to finish first-boot install and its tunnel to come up"
BASE_URL=""; waited=0; timeout=900
while [ "$waited" -lt "$timeout" ]; do
  if [ "$(fly_exec 'curl -s -o /dev/null -w %{http_code} http://localhost/healthz')" = "200" ]; then
    BASE_URL="$(fly_exec 'grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" /var/log/sidekick/cloudflared.log | head -1')"
    [ -n "$BASE_URL" ] && break
  fi
  echo "  ... still provisioning (${waited}s/${timeout}s)" >&2
  sleep 20; waited=$((waited + 20))
done
[ -n "$BASE_URL" ] || { echo "error: timed out waiting for the server/tunnel on fly." >&2; exit 1; }

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "fly" "$CREATED_AT")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}"
