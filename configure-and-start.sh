#!/usr/bin/env bash
# Renders the Caddyfile and supervisord config from the templates provision.sh
# laid down, using secrets that are only available at container-start /
# first-boot time (never baked into the published image), then starts the
# service manager. This is the one script that needs AUTH_TOKEN/SERVER_ID.
set -euo pipefail

# cloud-init/first-boot runs this with no HOME set, which makes some tools
# (e.g. `caddy hash-password`) warn about missing user config dirs. Give them
# a sane HOME.
export HOME="${HOME:-/root}"

: "${AUTH_TOKEN:?AUTH_TOKEN env var is required}"
: "${SERVER_ID:?SERVER_ID env var is required}"

log() { echo "[configure] $*"; }

mkdir -p /var/log/sidekick /etc/sidekick

log "hashing auth token for Caddy basicauth"
AUTH_TOKEN_BCRYPT_HASH="$(caddy hash-password --plaintext "$AUTH_TOKEN")"

sed "s#__AUTH_TOKEN_BCRYPT_HASH__#${AUTH_TOKEN_BCRYPT_HASH}#g" \
  /etc/sidekick/Caddyfile.tmpl > /etc/sidekick/Caddyfile

sed "s#__AUTH_TOKEN__#${AUTH_TOKEN}#g" \
  /etc/sidekick/supervisord.sidekick.conf.tmpl > /etc/supervisor/conf.d/sidekick.conf

if [ "${SIDEKICK_INIT:-systemd}" = "container" ]; then
  log "starting supervisord in foreground (container mode)"
  exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
else
  log "starting supervisor via systemd (bare-VM mode)"
  systemctl enable supervisor >/dev/null 2>&1 || true
  systemctl restart supervisor
fi
