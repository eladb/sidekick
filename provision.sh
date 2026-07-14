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

# On a fresh cloud VM, cloud-init / unattended-upgrades often still hold the
# dpkg lock when we start. Without this, apt-get fails immediately ("Could
# not get lock") and, under `set -e`, aborts provisioning before anything is
# installed. This makes every apt-get invocation wait for the lock instead.
mkdir -p /etc/apt/apt.conf.d
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99sidekick-lock

# Some cloud base images (e.g. Hetzner's Debian 12) ship with root's password
# marked expired. That makes chfn — invoked by package postinst scripts that
# create system users (pulseaudio's `pulse` user is the one that bites) — fail
# with "authentication token is no longer valid", which aborts apt under
# `set -e`. Clear the expiry so those postinsts succeed.
chage -d "$(date +%Y-%m-%d)" -M -1 root 2>/dev/null || true

log "installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg jq openssl \
  python3 python3-pip python3-venv python3-dev build-essential \
  supervisor \
  chromium \
  xvfb openbox xserver-xorg-core x11-utils x11-xkb-utils x11-xserver-utils \
  libx11-xcb1 libxcb-dri3-0 libxkbcommon0 libxdamage1 libxfixes3 libxtst6 libxext6 \
  libpulse0 pulseaudio

ARCH="$(dpkg --print-architecture)"
# ttyd's release assets are named by uname-style arch (x86_64/aarch64), not
# dpkg's (amd64/arm64), so map to the uname form for that download.
case "$ARCH" in
  amd64) UNAME_ARCH="x86_64" ;;
  arm64) UNAME_ARCH="aarch64" ;;
  *) UNAME_ARCH="$(uname -m)" ;;
esac

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
# The Debian caddy package enables+starts caddy.service on :80 with a default
# config. We run our own Caddy under supervisord instead, so stop and disable
# the packaged service to free :80 (|| true so it's harmless during a
# container image build where systemd isn't running).
systemctl disable --now caddy 2>/dev/null || true

log "installing ttyd"
curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${UNAME_ARCH}" -o /usr/local/bin/ttyd
chmod +x /usr/local/bin/ttyd

log "installing selkies (from PyPI)"
# PyPI ships the selkies wheel directly; simpler and more robust than
# constructing a GitHub release-asset URL (whose tag/filename scheme has
# drifted across versions).
PIP_BREAK_SYSTEM_PACKAGES=1 pip3 install --no-cache-dir selkies

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
