---
name: sidekick
description: >-
  Set up and drive a "sidekick" server — a persistent remote box the agent
  fully controls over a Cloudflare tunnel via one token: a CDP-drivable Chromium
  browser, a shell/exec API, a live watch-along view, and static+CGI webapp
  hosting on its own public URL. Use this WHENEVER the user points you at the
  sidekick repo, says "sidekick", has (or mentions) a SIDEKICK_TOKEN, wants to
  deploy or connect to a sidekick, drive a remote browser they own, run commands
  on a persistent box that survives across sessions, or host a webapp/backend on
  a public URL. Also use it to install itself so the sidekick stays usable from
  any future project — don't wait for the user to say the word "skill".
---

# Sidekick

A **sidekick** is a remote box an agent deploys once and reconnects to across
sessions. Everything is reached over a Cloudflare tunnel with **no inbound
ports and no SSH** — the only credential is a single `base64url` **token**.

Capabilities (each is a URL inside the token):
- **Browser** (`cdp_url`) — a real Chromium you drive over CDP (Playwright/Puppeteer).
- **Exec** (`exec_url`) — run shell commands programmatically.
- **Shell** (`shell_url`) — an interactive terminal in the browser.
- **Watch** (`watch_url`) — a live view of the browser, for a human to open.
- **Webapp** (`webapp_url`) — host a static + CGI app on its own **public** URL.

## Step 0 — is a sidekick already configured?

Check for a token before doing anything else:
1. `SIDEKICK_TOKEN` in the environment, or
2. a saved file (`./sidekick-token.txt`, or `~/.sidekick/token`).

If you find one → skip to **Using a sidekick**. If not → **Setup**.

## Setup

Ask the user which path they want:

### A) Use an existing sidekick
They already have a token (from a previous deploy or a teammate).
1. Get the token — from `SIDEKICK_TOKEN`, or ask them to paste it.
2. Persist it so future sessions find it: `mkdir -p ~/.sidekick && printf '%s' "<token>" > ~/.sidekick/token` and suggest they add `export SIDEKICK_TOKEN=...` to their shell profile / agent secrets.
3. Decode it (see **Using a sidekick**) and confirm the server is reachable (`GET <base_url>/healthz` → `ok`).

### B) Deploy a new sidekick
This needs the **sidekick repo** (the user pointed you at it). From the repo root:
1. Pick a platform and confirm its one dependency is present:
   | Platform | Needs |
   |---|---|
   | `fly` | `FLY_API_TOKEN` in env + `python3` |
   | `ec2` | `aws` CLI configured |
   | `hetzner` | `HCLOUD_TOKEN` in env + `cloudflared` + `python3` |
   | `docker` | a reachable Docker daemon |
2. Run: `scripts/install.sh --platform <fly|ec2|hetzner|docker>`
   It deploys the box, waits for the tunnel, and prints the token (also saved to
   `sidekick-token.txt`, which is gitignored). fly/Docker use a prebuilt image
   (~1-2 min); EC2/Hetzner build from source (~4-12 min).
3. Persist the printed token as in path A, step 2.

### Then: install this skill so it works everywhere
So the user doesn't need the repo again, offer to install this skill globally:
```bash
mkdir -p ~/.claude/skills && cp -r .claude/skills/sidekick ~/.claude/skills/sidekick
```
After that, any future session can drive their sidekick from any project — just
ensure `SIDEKICK_TOKEN` (or `~/.sidekick/token`) is available.

## Using a sidekick

**Decode the token** — it's `base64url(JSON)`. Read the fields you need:
```bash
python3 - "$SIDEKICK_TOKEN" <<'PY'
import base64, json, sys
t = sys.argv[1]; t += "=" * (-len(t) % 4)
d = json.loads(base64.urlsafe_b64decode(t))
for k in ("base_url","cdp_url","exec_url","shell_url","watch_url","webapp_url","auth_token"):
    print(k, "=", d.get(k))
PY
```

Then pick the capability. **Full, copy-pasteable recipes for each live in
[`references/using-a-sidekick.md`](references/using-a-sidekick.md)** — read it
when you actually need to drive one; the essentials:

- **Drive the browser** → `chromium.connectOverCDP(cdp_url)` (Playwright), then
  navigate/screenshot/scrape like any browser.
- **Run a command** → `POST exec_url` with `{"cmd","cwd","timeout_sec"}`; the
  response is newline-delimited JSON (`{"stream","data"}` lines, then
  `{"exit_code"}`). This is your general-purpose "do something on the box" tool.
- **Interactive shell** → open `shell_url` in a browser, or drive its WebSocket.
- **Watch live** → hand `watch_url` to the **human** to open in a browser (it's
  a plain clickable link; don't try to render it yourself).
- **Host a webapp** → write static files to `/srv/sidekick/www` and executable
  CGI scripts to `/srv/sidekick/cgi-bin` (using `exec`); they're served publicly
  at `webapp_url`. See the reference for the write-and-serve recipe.

## Notes

- **The token is root-equivalent.** Anyone with it can run arbitrary commands on
  the box. Treat it like an SSH key: never commit it or paste it publicly.
- **`webapp_url` is public and unauthenticated** — it's meant for end users.
  Don't put secrets in `/srv/sidekick`, and validate input in CGI scripts.
- The quick-tunnel URLs change if the box restarts; if a `*_url` stops working,
  re-read the token from the box (or redeploy) to get the current one.
