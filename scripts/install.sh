#!/usr/bin/env bash
# One command to deploy the sidekick server. Generates the server's secrets,
# dispatches to the chosen platform script, and prints the one token an
# agent needs to reconnect to this server in every future session.
#
# Usage:
#   scripts/install.sh --platform fly|ec2|hetzner|docker [options]
#
# Platform-specific behavior is documented in scripts/platforms/*.sh and in
# README.md. No SSH is used anywhere in any platform, by design.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PLATFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      PLATFORM="$2"; shift 2 ;;
    --platform=*)
      PLATFORM="${1#*=}"; shift ;;
    -h|--help)
      grep -E '^# ?' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1 ;;
  esac
done

case "$PLATFORM" in
  fly|ec2|hetzner|docker) ;;
  "")
    echo "error: --platform is required (fly|ec2|hetzner|docker)" >&2
    exit 1 ;;
  *)
    echo "error: unknown platform '$PLATFORM' (want: fly|ec2|hetzner|docker)" >&2
    exit 1 ;;
esac

export AUTH_TOKEN="${AUTH_TOKEN:-$(sidekick_gen_secret)}"
export SERVER_ID="${SERVER_ID:-$(sidekick_gen_server_id)}"

echo "==> deploying sidekick to $PLATFORM (server_id=$SERVER_ID)"
exec "$SCRIPT_DIR/platforms/${PLATFORM}.sh"
