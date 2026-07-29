#!/usr/bin/env bash
# Shared helpers for scripts/platforms/*.sh. Sourced, not executed directly.

sidekick_gen_secret() {
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
}

sidekick_gen_server_id() {
  openssl rand -hex 8
}

# Polls an arbitrary "give me recent logs" command until it contains a
# SIDEKICK_TUNNEL_URL=... sentinel line, or times out. Platform scripts pass
# in whatever log-fetch command fits them (`docker logs`, `fly logs`,
# `aws ec2 get-console-output ...`) — this function has no platform-specific
# knowledge. Hetzner can't use this (no text console); it uses the rendezvous
# in scripts/lib/rendezvous.sh instead.
sidekick_wait_for_tunnel_url() {
  # Optional 3rd arg picks the sentinel: SIDEKICK_TUNNEL_URL (control, default)
  # or SIDEKICK_WEBAPP_URL (the public webapp tunnel).
  local log_cmd="$1" timeout_sec="${2:-180}" sentinel="${3:-SIDEKICK_TUNNEL_URL}" interval=5 waited=0 url=""
  while [ "$waited" -lt "$timeout_sec" ]; do
    url="$(eval "$log_cmd" 2>/dev/null | grep -oE "${sentinel}=https://[a-zA-Z0-9.-]+" | tail -n1 | cut -d= -f2- || true)"
    if [ -n "$url" ]; then
      echo "$url"
      return 0
    fi
    echo "  ... waiting for ${sentinel} (${waited}s/${timeout_sec}s)" >&2
    sleep "$interval"
    waited=$((waited + interval))
  done
  return 1
}

# Emits the base64url sidekick token on stdout. All service URLs share one
# credential (basic auth, username "sidekick", password = auth_token) so an
# agent only needs to remember one secret.
sidekick_build_token() {
  # webapp_url (6th arg) is the public webapp tunnel's URL; the box serves
  # static files + CGI there. Empty if the platform didn't discover it.
  local server_id="$1" base_url="$2" auth_token="$3" platform="$4" created_at="$5" webapp_url="${6:-}"
  local host="${base_url#https://}"
  local json
  json=$(cat <<EOF
{"v":1,"server_id":"${server_id}","base_url":"${base_url}","auth_token":"${auth_token}","cdp_url":"https://sidekick:${auth_token}@${host}","watch_url":"https://${host}/vnc.html?autoconnect=true&reconnect=true&token=${auth_token}","shell_url":"https://sidekick:${auth_token}@${host}/shell","exec_url":"https://sidekick:${auth_token}@${host}/exec","webapp_url":"${webapp_url}","platform":"${platform}","created_at":"${created_at}"}
EOF
)
  printf '%s' "$json" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

sidekick_print_summary() {
  local token="$1" base_url="$2" out_file="$3" webapp_url="${4:-}"
  echo "$token" > "$out_file"
  chmod 600 "$out_file" 2>/dev/null || true
  cat >&2 <<EOF

Sidekick server is up: ${base_url}
${webapp_url:+Public webapp URL:     ${webapp_url}  (serve static + CGI from /srv/sidekick)}

Your sidekick token (save this — it's the ONLY credential you'll need to
reconnect from any future agent session; treat it like a private key):

${token}

Also saved to: ${out_file}

Give your agent this token (e.g. as a SIDEKICK_TOKEN env var / secret). It
decodes to JSON with cdp_url, watch_url, shell_url, exec_url, and webapp_url —
each is a ready-to-use URL.
EOF
}
