# sidekick

A self-hosted "agent sidekick" server: a persistent box your AI agent can
deploy for itself and keep coming back to across sessions. It ships with a
remote, CDP-drivable browser, a live watch-along view, and a shell/exec
API — all exposed through a free Cloudflare Tunnel, with no inbound ports,
no SSH, and no Docker required on the box.

## Quickstart

```bash
git clone https://github.com/eladb/sidekick.git
cd sidekick
scripts/install.sh --platform fly    # or: ec2 | hetzner | docker
```

This deploys the server, waits for its tunnel to come up, and prints one
big token to your terminal (and saves it to `sidekick-token.txt`,
gitignored). Give that token to your agent — as `SIDEKICK_TOKEN` in its
env/secrets — and it's everything the agent needs to reconnect to this same
server from any future session, from anywhere.

```bash
scripts/install.sh --platform ec2       # AWS, no SSH key needed
scripts/install.sh --platform hetzner   # Hetzner Cloud, no SSH key needed
scripts/install.sh --platform docker    # any Docker host you already have
```

Required tooling per platform: `flyctl` for fly.io, `aws` (configured) for
EC2, `hcloud` + `websocat` for Hetzner, `docker` for the Docker path. Each
script fails fast with a clear message if its CLI is missing.

## The token

The token is `base64url(JSON)`. Decoded, it looks like:

```json
{
  "v": 1,
  "server_id": "a1b2c3d4e5f6a7b8",
  "base_url": "https://xxxx.trycloudflare.com",
  "auth_token": "…",
  "cdp_url": "https://sidekick:…@xxxx.trycloudflare.com",
  "watch_url": "https://sidekick:…@xxxx.trycloudflare.com",
  "shell_url": "https://sidekick:…@xxxx.trycloudflare.com/shell",
  "exec_url": "https://sidekick:…@xxxx.trycloudflare.com/exec",
  "platform": "fly",
  "created_at": "2026-07-14T00:00:00Z"
}
```

Every service shares one credential (HTTP Basic Auth, username `sidekick`,
password `auth_token`), so each `*_url` is ready to use as-is:

- **`cdp_url`** — point Playwright/Puppeteer at this
  (`chromium.connectOverCDP(cdp_url)`) to drive the remote browser.
- **`watch_url`** — open in a browser tab to watch the browser live
  (Selkies).
- **`shell_url`** — open in a browser tab for an interactive terminal
  (ttyd), or drive it programmatically over its WebSocket protocol.
- **`exec_url`** — `POST` `{"cmd": "...", "cwd": "...", "timeout_sec": ...}`
  for clean programmatic command execution; response is newline-delimited
  JSON: `{"stream":"stdout"|"stderr","data":"..."}` lines followed by
  `{"exit_code": N}`.

**The token is a root-equivalent bearer credential.** Anyone who has it can
run arbitrary commands on the box. Treat it exactly like an SSH private key
or a cloud API key — store it in a secrets manager / your agent's encrypted
env, never commit it, never paste it somewhere public.

## Architecture

One `provision.sh` installs everything with plain `apt-get` (Chromium,
Xvfb, Selkies, ttyd, a small `execd` service, Caddy, cloudflared) —
supervisord manages the process tree either inside a container (fly.io, or
the optional Docker path) or directly on a bare Debian VM (EC2, Hetzner).
There's no hard Docker dependency: EC2 and Hetzner install straight onto
the OS via cloud-init, no container runtime involved.

Cloudflare's free quick tunnel (`cloudflared tunnel --url ...`) is the only
ingress path — no inbound ports are opened anywhere, which is also why none
of the platform scripts use SSH: there's nothing to SSH into from the
outside, and the box needs no SSH out either. The interactive shell
(`ttyd`) and exec API (`execd`) exist specifically to give an agent
SSH-equivalent access over that same HTTP(S)/WebSocket tunnel.

Caddy fronts everything on port 80 behind the tunnel:

| Path                     | Backend            | Auth                          |
|---------------------------|---------------------|-------------------------------|
| `/healthz`                | —                   | none                          |
| `/json*`, `/devtools/*`   | Chromium CDP (9222) | Caddy `basicauth`             |
| `/exec`                   | execd (8090)        | checked by execd itself       |
| `/shell*`                 | ttyd (7681)         | checked by ttyd itself        |
| everything else (root)    | Selkies (8081)      | checked by Selkies itself     |

CDP and Selkies are deliberately **not** proxied under a prefix like
`/cdp`/`/watch`: Chrome's DevTools endpoint reports its own paths
(`/json/version`, `/devtools/browser/<id>`) at the root with no way to tell
it about a reverse-proxy prefix, and Selkies' bundled web client assumes
root-relative asset paths. Prefixing either would break on the client's
very next request. `/exec` and `/shell` don't have that problem (execd is
ours, and ttyd supports `--base-path`), so they get real prefixes.

## Watch-along transport

Selkies defaults to its **WebSocket transport**: a single TCP stream, no
STUN/TURN, works through the Cloudflare tunnel on every platform including
ones with no public IP (fly.io, and sandboxed "cloud container" agent
environments). Its WebRTC transport is available as an opt-in
(`SIDEKICK_WATCH_TRANSPORT=webrtc`) for lower latency, but WebRTC's actual
media path is a separate UDP/TCP connection that the tunnel does **not**
carry — on a host with a public IP (EC2, Hetzner) it typically just
connects directly, but on a NAT'd host you'll need to supply a TURN relay
via `SIDEKICK_TURN_*` env vars (see `.env.example`) for it to work at all.

## Known limitations (MVP)

- The Cloudflare **quick tunnel URL is stable only as long as the process
  doesn't restart** — a crash/restart gets a new `trycloudflare.com`
  subdomain, invalidating the token's `base_url`. A named Cloudflare Tunnel
  (stable hostname, requires a free Cloudflare account) is the natural
  upgrade path here and may land later.
- Hetzner's serial-console URL scrape (`hcloud server request-console`)
  hasn't been exercised against a live account in development — if it times
  out, the script prints a manual fallback (check the console in the
  Hetzner dashboard).
- Debian 12 is the target OS (Ubuntu's `chromium-browser` package is a snap
  wrapper that doesn't work in a container or a minimal cloud-init install).
- Audio capture (pulseaudio → Selkies) is wired up but hasn't been verified
  against a live stream; the watch-along view is guaranteed to work for
  video even if audio turns out to need more tuning.

## Roadmap

More services are planned to run alongside the browser on the same box —
starting with a Caddy-hosted webapp/CGI server — reusing the same
`provision.sh` + supervisord + token pattern established here.
