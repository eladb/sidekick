# Using a sidekick — recipes

Copy-pasteable recipes for each capability. All you need is the token; decode it
first (see SKILL.md) to get the `*_url` fields and `auth_token`.

Auth model: `cdp_url`, `shell_url`, `exec_url` embed HTTP Basic credentials
(`sidekick:<auth_token>`) right in the URL, so they work as-is with programmatic
clients. `watch_url` and `webapp_url` don't need credentials from you (the watch
link carries a `?token=`; the webapp is public).

## Table of contents
- [Drive the browser (CDP)](#drive-the-browser-cdp)
- [Run commands (exec)](#run-commands-exec)
- [Interactive shell](#interactive-shell)
- [Watch live](#watch-live)
- [Host a webapp (static + CGI)](#host-a-webapp-static--cgi)

## Drive the browser (CDP)

`cdp_url` is a Chrome DevTools Protocol endpoint. Point Playwright or Puppeteer
at it and drive a real Chromium.

```javascript
// Node + Playwright
const { chromium } = require('playwright');
const browser = await chromium.connectOverCDP(cdpUrl); // cdp_url from the token
const ctx = browser.contexts()[0] || await browser.newContext();
const page = ctx.pages()[0] || await ctx.newPage();
await page.goto('https://example.com');
console.log(await page.title());
await page.screenshot({ path: 'shot.png' });
// Don't browser.close() unless you mean to close the remote browser.
```

```python
# Python + Playwright
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    browser = p.chromium.connect_over_cdp(cdp_url)
    page = browser.contexts[0].pages[0] if browser.contexts and browser.contexts[0].pages else browser.new_page()
    page.goto("https://example.com")
    print(page.title())
```

The human can watch you drive it live via `watch_url` (below).

## Run commands (exec)

`exec_url` runs a command through a shell on the box (`bash -lc`), so pipes,
`&&`, and redirection work. It's the general-purpose "do something on the box"
tool — including deploying webapp files.

Request: `POST` JSON `{"cmd": "...", "cwd": "...", "timeout_sec": 60}` (cwd and
timeout optional). Response: newline-delimited JSON — zero or more
`{"stream":"stdout"|"stderr","data":"..."}` lines, then `{"exit_code": N}`.

```bash
# exec_url already contains sidekick:<auth_token>@host
curl -sS -X POST "$EXEC_URL" -H 'Content-Type: application/json' \
  -d '{"cmd":"uname -a && whoami"}'
# -> {"stream":"stdout","data":"Linux ...\n"} ... {"exit_code":0}
```

```python
import requests, json
r = requests.post(exec_url, json={"cmd": "ls -la /srv/sidekick"}, stream=True)
out, code = "", None
for line in r.iter_lines():
    if not line: continue
    msg = json.loads(line)
    if "data" in msg: out += msg["data"]
    if "exit_code" in msg: code = msg["exit_code"]
print(code, out)
```

## Interactive shell

`shell_url` is a browser terminal (ttyd) — hand it to a human to open, or drive
its WebSocket protocol programmatically. For agent automation, prefer `exec`.

## Watch live

`watch_url` is a plain clickable link (a noVNC view of the box's screen). Give
it to the **human** to open in a browser tab — don't try to fetch/render it
yourself. They'll see whatever the browser is doing in real time.

## Host a webapp (static + CGI)

The box serves a public webapp at `webapp_url` from two directories, which you
populate over `exec`:
- `/srv/sidekick/www` — static files. `index.html` is served at `/`.
- `/srv/sidekick/cgi-bin` — **executable** scripts, run per-request as CGI at
  `/cgi-bin/<name>` (Caddy → fcgiwrap). Any language; read the request from the
  CGI environment (`REQUEST_METHOD`, `QUERY_STRING`, stdin for POST) and print
  headers, a blank line, then the body.

Deploy a frontend + a JSON backend via `exec` (heredocs keep it one call each):

```bash
# static page
curl -sS -X POST "$EXEC_URL" -H 'Content-Type: application/json' -d '{"cmd":"cat > /srv/sidekick/www/index.html <<HTML\n<h1>my app</h1><script>fetch(\"/cgi-bin/api\").then(r=>r.json()).then(d=>document.body.append(JSON.stringify(d)))</script>\nHTML"}'

# a one-file JSON backend, made executable
curl -sS -X POST "$EXEC_URL" -H 'Content-Type: application/json' -d '{"cmd":"cat > /srv/sidekick/cgi-bin/api <<CGI\n#!/usr/bin/env bash\necho \"Content-Type: application/json\"; echo\necho \"{\\\"ok\\\": true, \\\"method\\\": \\\"$REQUEST_METHOD\\\"}\"\nCGI\nchmod +x /srv/sidekick/cgi-bin/api"}'
```

When writing scripts with tricky quoting, it's often cleaner to base64-encode
the file content locally and `echo <b64> | base64 -d > <path>` over `exec`.

Now `webapp_url/` serves the page and `webapp_url/cgi-bin/api` the backend.
Because it's public, give `webapp_url` to anyone who should use the app.
