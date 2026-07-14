#!/usr/bin/env bash
# Renders the Caddyfile and supervisord config from the templates provision.sh
# laid down, using secrets that are only available at container-start /
# first-boot time (never baked into the published image), then starts the
# service manager. This is the one script that needs AUTH_TOKEN/SERVER_ID.
set -euo pipefail

: "${AUTH_TOKEN:?AUTH_TOKEN env var is required}"
: "${SERVER_ID:?SERVER_ID env var is required}"

log() { echo "[configure] $*"; }

mkdir -p /var/log/sidekick /etc/sidekick

log "hashing auth token for Caddy basicauth"
AUTH_TOKEN_BCRYPT_HASH="$(caddy hash-password --plaintext "$AUTH_TOKEN")"

sed "s#__AUTH_TOKEN_BCRYPT_HASH__#${AUTH_TOKEN_BCRYPT_HASH}#g" \
  /etc/sidekick/Caddyfile.tmpl > /etc/sidekick/Caddyfile

SELKIES_EXTRA_ARGS=""
if [ "${SIDEKICK_WATCH_TRANSPORT:-websocket}" = "webrtc" ]; then
  log "watch-along transport: webrtc"
  SELKIES_EXTRA_ARGS="--mode=webrtc"
  [ -n "${SIDEKICK_STUN_HOST:-}" ] && SELKIES_EXTRA_ARGS+=" --stun_host=${SIDEKICK_STUN_HOST}"
  [ -n "${SIDEKICK_STUN_PORT:-}" ] && SELKIES_EXTRA_ARGS+=" --stun_port=${SIDEKICK_STUN_PORT}"
  [ -n "${SIDEKICK_TURN_HOST:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_host=${SIDEKICK_TURN_HOST}"
  [ -n "${SIDEKICK_TURN_PORT:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_port=${SIDEKICK_TURN_PORT}"
  [ -n "${SIDEKICK_TURN_PROTOCOL:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_protocol=${SIDEKICK_TURN_PROTOCOL}"
  [ -n "${SIDEKICK_TURN_USERNAME:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_username=${SIDEKICK_TURN_USERNAME}"
  [ -n "${SIDEKICK_TURN_PASSWORD:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_password=${SIDEKICK_TURN_PASSWORD}"
  [ -n "${SIDEKICK_TURN_SHARED_SECRET:-}" ] && SELKIES_EXTRA_ARGS+=" --turn_shared_secret=${SIDEKICK_TURN_SHARED_SECRET}"
else
  log "watch-along transport: websocket (default, no STUN/TURN needed)"
fi

sed -e "s#__AUTH_TOKEN__#${AUTH_TOKEN}#g" \
    -e "s#__SELKIES_EXTRA_ARGS__#${SELKIES_EXTRA_ARGS}#g" \
  /etc/sidekick/supervisord.sidekick.conf.tmpl > /etc/supervisor/conf.d/sidekick.conf

if [ "${SIDEKICK_INIT:-systemd}" = "container" ]; then
  log "starting supervisord in foreground (container mode)"
  exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
else
  log "starting supervisor via systemd (bare-VM mode)"
  systemctl enable supervisor >/dev/null 2>&1 || true
  systemctl restart supervisor
fi
