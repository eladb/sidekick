# Show HN launch kit

## Title
Show HN: Sidekick – a persistent box your AI agent deploys for itself

*(76 chars. Alt: "Show HN: Sidekick – give your AI agent a remote browser and shell it can revisit")*

## URL
https://github.com/eladb/sidekick

## Post body

AI agents are stateless between sessions — every run starts from a blank
machine, re-installs everything, and throws it away. I wanted an agent to
have *one box of its own* that it deploys once and reconnects to from any
future session.

Sidekick is a small, self-hosted server for exactly that. You run one
install command and it gives you a single token. Hand that token to your
agent as `SIDEKICK_TOKEN` and it has, from anywhere:

- a remote **CDP-drivable Chromium** (point Playwright/Puppeteer at it),
- a live **watch-along** view you open in a browser tab to see the agent
  drive the browser in real time (noVNC over the tunnel — works even with no
  public IP),
- a **shell** (ttyd) and a clean **exec** API for commands.

Everything is exposed through a free Cloudflare quick tunnel, so there are
**no inbound ports, no SSH, and no Docker required on the box**. It deploys to
fly.io, EC2, Hetzner, or any Docker host, from the same `provision.sh`. The
trick is splitting install (no secrets) from configure-at-boot (secrets), so
the same script feeds a prebuilt image and a from-source bare-VM boot without
ever baking secrets into an image.

Honest limitations (there's a "Known limitations" section in the README):
the Cloudflare quick-tunnel URL is only stable until the process restarts (a
named tunnel is the planned upgrade); Hetzner needs a return-path rendezvous
to discover its URL; the watch-along is video-only.

It's MIT-licensed and deliberately dependency-light — plain shell + apt +
supervisord. I'd love feedback on the architecture, the tunnel/auth model,
and where this should go next (first up: a Caddy-hosted webapp/CGI server on
the same box).

## First comment (post immediately after)

Author here. A few implementation notes for the curious:

- **Why noVNC and not WebRTC?** An earlier design used Selkies for
  lower-latency WebRTC, but the shipping build needs a heavy GStreamer stack
  and a TURN relay to cross the tunnel. noVNC streams over a single WebSocket
  that traverses the Cloudflare tunnel on every platform with no STUN/TURN —
  simpler and tunnel-native.
- **Auth is one token, four URLs.** The token is `base64url(JSON)` carrying
  per-service URLs all gated by the same secret. Programmatic URLs embed it as
  HTTP Basic Auth; the watch URL carries it as `?token=` because browsers
  strip credentials from `user:pass@host` links — Caddy validates it once and
  stamps a cookie.
- **No SSH anywhere**, in or out. The exec/shell endpoints exist to give the
  agent SSH-equivalent access over the same HTTPS/WebSocket tunnel.

Happy to answer anything about the platform scripts or the provision/configure
split.

## Posting tips
- Post Tue–Thu, ~8–10am ET. Add the demo GIF to the README first.
- Reply fast and technically in the first hour; don't be defensive about limitations.
