#!/usr/bin/env bash
# fly.io, driven straight through the fly Machines API over HTTPS (needs only
# FLY_API_TOKEN — no flyctl, no SSH, no local Docker). Two modes:
#
#   default        : pull the prebuilt image (ghcr.io/eladb/sidekick), whose
#                    ENTRYPOINT runs configure-and-start.sh with secrets injected
#                    at runtime. Boots in ~1-2 min (pull + configure).
#   SIDEKICK_FROM_SOURCE=1 : boot a stock debian:bookworm-slim and run
#                    provision.sh + configure-and-start.sh from source at boot
#                    (container mode). No published image needed, but the first
#                    boot installs everything via apt (~10-12 min on fly's shared
#                    CPUs). Useful for hacking on provision.sh from a branch.
#
# Either way there's no prebuilt-vs-source lock-in and no registry to manage for
# the source path. fly's own inbound proxy/ports are unused (no fly "services")
# — the box only reaches out to Cloudflare's edge for the tunnel, and we discover
# the tunnel URL through the Machines API `exec` endpoint (no public port).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

: "${AUTH_TOKEN:?}" "${SERVER_ID:?}"
: "${FLY_API_TOKEN:?FLY_API_TOKEN is required (get one with: flyctl tokens create org, or from the fly dashboard)}"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required (used to build/parse the fly API JSON)." >&2; exit 1; }

IMAGE="${SIDEKICK_FLY_IMAGE:-ghcr.io/eladb/sidekick:latest}"
BASE_IMAGE="${SIDEKICK_FLY_BASE_IMAGE:-docker.io/library/debian:bookworm-slim}"
FROM_SOURCE="${SIDEKICK_FROM_SOURCE:-}"
APP_NAME="${SIDEKICK_FLY_APP:-sidekick-${SERVER_ID}}"
REGION="${SIDEKICK_FLY_REGION:-iad}"
ORG="${SIDEKICK_FLY_ORG:-personal}"
CPUS="${SIDEKICK_FLY_CPUS:-2}"
MEMORY="${SIDEKICK_FLY_MEMORY:-2048}"
REPO="${SIDEKICK_REPO:-eladb/sidekick}"
REPO_REF="${SIDEKICK_REPO_REF:-main}"
API="https://api.machines.dev/v1"
AUTH_HDR="Authorization: Bearer ${FLY_API_TOKEN}"

# Source-mode boot command: fetch source, provision, exec the service manager.
BOOT="set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates tar
mkdir -p /opt/sidekick-src
curl -fsSL \"https://github.com/${REPO}/archive/refs/heads/${REPO_REF}.tar.gz\" | tar xz -C /opt/sidekick-src --strip-components=1
chmod +x /opt/sidekick-src/provision.sh /opt/sidekick-src/configure-and-start.sh
/opt/sidekick-src/provision.sh
exec /opt/sidekick-src/configure-and-start.sh"

if [ -n "$FROM_SOURCE" ]; then
  MACHINE_IMAGE="$BASE_IMAGE"; MODE_DESC="stock debian + install-on-boot (~10-12 min)"
else
  MACHINE_IMAGE="$IMAGE"; MODE_DESC="prebuilt image $IMAGE (~1-2 min)"
fi

echo "==> creating fly app $APP_NAME (org: $ORG)"
create_app="$(curl -fsS -X POST "$API/apps" -H "$AUTH_HDR" -H 'Content-Type: application/json' \
  -d "{\"app_name\":\"${APP_NAME}\",\"org_slug\":\"${ORG}\"}" 2>&1)" || {
  echo "error: failed to create app: $create_app" >&2; exit 1; }

# Build the machine config JSON with python3. In source mode we override the
# init command; in image mode we let the image's baked ENTRYPOINT run.
MACHINE_CFG="$(BOOT="$BOOT" AUTH_TOKEN="$AUTH_TOKEN" SERVER_ID="$SERVER_ID" \
  REGION="$REGION" CPUS="$CPUS" MEMORY="$MEMORY" MACHINE_IMAGE="$MACHINE_IMAGE" FROM_SOURCE="$FROM_SOURCE" python3 -c '
import json, os
cfg = {
  "region": os.environ["REGION"],
  "config": {
    "image": os.environ["MACHINE_IMAGE"],
    "env": {"AUTH_TOKEN": os.environ["AUTH_TOKEN"], "SERVER_ID": os.environ["SERVER_ID"], "SIDEKICK_INIT": "container"},
    "guest": {"cpu_kind": "shared", "cpus": int(os.environ["CPUS"]), "memory_mb": int(os.environ["MEMORY"])},
    "auto_destroy": False,
    "restart": {"policy": "on-failure", "max_retries": 3},
  },
}
if os.environ.get("FROM_SOURCE"):
    cfg["config"]["init"] = {"exec": ["/bin/bash", "-lc", os.environ["BOOT"]]}
print(json.dumps(cfg))')"

echo "==> launching machine: $MODE_DESC"
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

echo "==> waiting for the server and its tunnel to come up"
BASE_URL=""; waited=0; timeout=900
while [ "$waited" -lt "$timeout" ]; do
  if [ "$(fly_exec 'curl -s -o /dev/null -w %{http_code} http://localhost/healthz')" = "200" ]; then
    BASE_URL="$(fly_exec 'grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" /var/log/sidekick/cloudflared.log | head -1')"
    [ -n "$BASE_URL" ] && break
  fi
  echo "  ... still coming up (${waited}s/${timeout}s)" >&2
  sleep 20; waited=$((waited + 20))
done
[ -n "$BASE_URL" ] || { echo "error: timed out waiting for the server/tunnel on fly." >&2; exit 1; }

# The public webapp tunnel usually comes up a few seconds behind the control
# tunnel; give it a short window (best-effort — don't fail the deploy over it).
WEBAPP_URL=""; wwaited=0
while [ "$wwaited" -lt 60 ]; do
  WEBAPP_URL="$(fly_exec 'grep -oE "https://[a-z0-9-]+\.trycloudflare\.com" /var/log/sidekick/webapp-cloudflared.log | head -1')"
  [ -n "$WEBAPP_URL" ] && break
  sleep 10; wwaited=$((wwaited + 10))
done

CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
TOKEN="$(sidekick_build_token "$SERVER_ID" "$BASE_URL" "$AUTH_TOKEN" "fly" "$CREATED_AT" "$WEBAPP_URL")"
sidekick_print_summary "$TOKEN" "$BASE_URL" "${SIDEKICK_TOKEN_FILE:-./sidekick-token.txt}" "$WEBAPP_URL"
