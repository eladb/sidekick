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
EC2, `hcloud` + `cloudflared` + `python3` for Hetzner, `docker` for the
Docker path. Each script fails fast with a clear message if its CLI is
missing. (Hetzner needs `cloudflared` because it has no text console to
scrape — the box reports its URL back over a return-path tunnel the
installer runs; see the note in "Known limitations".)

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
  (noVNC).
- **`shell_url`** — open in a browser tab for an interactive terminal
  (ttyd), or drive it programmatically over its WebSocket protocol.
- **`exec_url`** — `POST` `{"cmd": "...", "cwd": "...", "timeout_sec": ...}`
  for clean programmatic command execution; `cmd` runs through a shell
  (`bash -lc`), so pipes, `&&`, and redirection work. Response is
  newline-delimited JSON: `{"stream":"stdout"|"stderr","data":"..."}` lines
  followed by `{"exit_code": N}`.

**The token is a root-equivalent bearer credential.** Anyone who has it can
run arbitrary commands on the box. Treat it exactly like an SSH private key
or a cloud API key — store it in a secrets manager / your agent's encrypted
env, never commit it, never paste it somewhere public.

## Architecture

One `provision.sh` installs everything with plain `apt-get` (Chromium,
Xvfb/openbox, x11vnc + noVNC/websockify, ttyd, a small `execd` service,
Caddy, cloudflared) — supervisord manages the process tree either inside a
container (fly.io, or the optional Docker path) or directly on a bare Debian
VM (EC2, Hetzner). There's no hard Docker dependency: EC2 and Hetzner install
straight onto the OS via cloud-init, no container runtime involved.

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
| everything else (root)    | noVNC (6080)        | Caddy `basic_auth`            |

CDP is deliberately **not** proxied under a prefix like `/cdp`: Chrome's
DevTools endpoint reports its own paths (`/json/version`,
`/devtools/browser/<id>`) at the root with no way to tell it about a
reverse-proxy prefix, so prefixing would break the client's follow-up
WebSocket connection. The noVNC viewer likewise lives at the root
(`/vnc.html` + its assets + the `/websockify` WebSocket). `/exec` and
`/shell` don't have that problem (execd is ours, and ttyd supports
`--base-path`), so they get real prefixes.

## Watch-along

The live viewer is **x11vnc + noVNC/websockify**: x11vnc exposes the
Chromium display (`:99`) as VNC on localhost, and websockify serves the
noVNC web client and bridges the browser's WebSocket to it. This streams
over a single WebSocket that traverses the Cloudflare tunnel on **every**
platform — including ones with no public IP (fly.io, sandboxed "cloud
container" agent environments) — with no STUN/TURN and no GStreamer. noVNC
has no auth of its own, so Caddy gates the root with `basic_auth` using the
same token as everything else.

(An earlier design used Selkies for lower-latency WebRTC streaming, but the
shipping Selkies build requires a heavy GStreamer stack and a TURN relay for
its media path to cross the tunnel; noVNC is the simpler, tunnel-native
choice.)

## Known limitations (MVP)

- The Cloudflare **quick tunnel URL is stable only as long as the process
  doesn't restart** — a crash/restart gets a new `trycloudflare.com`
  subdomain, invalidating the token's `base_url`. A named Cloudflare Tunnel
  (stable hostname, requires a free Cloudflare account) is the natural
  upgrade path here and may land later.
- **Hetzner uses a return-path rendezvous for URL discovery.** Hetzner
  exposes only a *graphical* VNC console — no text console API — so the
  installer can't scrape the tunnel URL from logs the way it can on
  Docker/fly/EC2. Instead the installer runs a tiny receiver behind its own
  ephemeral `cloudflared` tunnel and the box POSTs its URL back
  (`scripts/lib/rendezvous.sh`). This means the Hetzner installer must run
  somewhere with outbound reach to Cloudflare's edge (TCP/UDP 7844); in a
  locked-down sandbox that blocks it, run the Hetzner deploy from a host with
  open egress. The other platforms don't need this — they scrape logs and
  work anywhere.
- Debian 12 is the target OS (Ubuntu's `chromium-browser` package is a snap
  wrapper that doesn't work in a container or a minimal cloud-init install).
- The watch-along view is video-only (no audio); noVNC/VNC doesn't carry
  audio.

## Roadmap

More services are planned to run alongside the browser on the same box —
starting with a Caddy-hosted webapp/CGI server — reusing the same
`provision.sh` + supervisord + token pattern established here.
