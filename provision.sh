#!/usr/bin/env bash
# Installs every package the sidekick server needs directly on the OS
# (apt-get + a couple of upstream release binaries). No Docker involved —
# this same script is run both inside the Dockerfile (for the fly.io /
# optional-Docker image build) and directly on a bare VM via cloud-init
# (EC2, Hetzner, or any other apt-based Linux host).
#
# Idempotent and safe to re-run. Does NOT need any secrets (AUTH_TOKEN,
# SERVER_ID, ...) — those are only consumed later by configure-and-start.sh,
# which renders the actual runtime config and starts the services. Splitting
# it this way lets the same published container image be reused across
# deployments, with secrets injected at container-start time rather than
# baked into the image at build time.
set -euo pipefail

log() { echo "[provision] $*"; }

export DEBIAN_FRONTEND=noninteractive
SIDEKICK_HOME=/opt/sidekick
mkdir -p "$SIDEKICK_HOME"

log "installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg jq openssl \
  python3 python3-pip python3-venv \
  supervisor \
  chromium \
  xvfb openbox xserver-xorg-core x11-utils x11-xkb-utils x11-xserver-utils \
  libx11-xcb1 libxcb-dri3-0 libxkbcommon0 libxdamage1 libxfixes3 libxtst6 libxext6 \
  libpulse0 pulseaudio

ARCH="$(dpkg --print-architecture)"

log "installing cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
  > /etc/apt/sources.list.d/cloudflared.list
apt-get update -y
apt-get install -y cloudflared

log "installing caddy"
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

log "installing ttyd"
curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${ARCH}" -o /usr/local/bin/ttyd
chmod +x /usr/local/bin/ttyd

log "installing selkies"
SELKIES_VERSION="$(curl -fsSL https://api.github.com/repos/selkies-project/selkies/releases/latest | jq -r '.tag_name' | sed 's/[^0-9.-]*//g')"
curl -fsSL -o "/tmp/selkies-${SELKIES_VERSION}-py3-none-any.whl" \
  "https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-py3-none-any.whl"
PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install --no-cache-dir --force-reinstall \
  "/tmp/selkies-${SELKIES_VERSION}-py3-none-any.whl"
rm -f "/tmp/selkies-${SELKIES_VERSION}-py3-none-any.whl"

log "installing execd (bundled, no external deps)"
mkdir -p "$SIDEKICK_HOME/execd"
cp "$(dirname "$0")/services/execd/execd.py" "$SIDEKICK_HOME/execd/execd.py"

log "laying down config templates"
mkdir -p /etc/sidekick
cp "$(dirname "$0")/Caddyfile.tmpl" /etc/sidekick/Caddyfile.tmpl
cp "$(dirname "$0")/supervisord.sidekick.conf.tmpl" /etc/sidekick/supervisord.sidekick.conf.tmpl
cp "$(dirname "$0")/scripts/tunnel-watcher.sh" /usr/local/bin/sidekick-tunnel-watcher
chmod +x /usr/local/bin/sidekick-tunnel-watcher
cp "$(dirname "$0")/configure-and-start.sh" /usr/local/bin/sidekick-configure-and-start
chmod +x /usr/local/bin/sidekick-configure-and-start

log "cleaning up apt caches"
apt-get clean
rm -rf /var/lib/apt/lists/*

log "provisioning complete"
