# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities **privately**, not in a public issue.
Use GitHub's private vulnerability reporting: go to the repository's
**Security** tab → **Report a vulnerability**. We'll acknowledge the report and
work with you on a fix and coordinated disclosure.

## Security model — read before deploying

sidekick is a remote-access server. Understand what it exposes:

- **The token is a root-equivalent bearer credential.** Anyone who holds the
  token (or the `auth_token` inside it) can run arbitrary commands on the box
  via the exec/shell endpoints, drive the browser, and read the screen. Treat
  it exactly like an SSH private key: store it in a secrets manager or your
  agent's encrypted env, never commit it, never paste it anywhere public. The
  token file (`sidekick-token.txt`) is gitignored for this reason.

- **A single shared credential gates every service.** CDP, the shell, the exec
  API, and the watch view all authenticate with the same `auth_token`. There
  are no per-service scopes or per-user accounts — this is a single-tenant box.

- **Ingress is a Cloudflare quick tunnel.** No inbound ports are opened on the
  box; all access arrives over the outbound `cloudflared` tunnel. The
  `trycloudflare.com` hostname is effectively public — its secrecy is not a
  security boundary. Auth is enforced by Caddy (basic-auth / token) in front of
  every service, so treat the URL as discoverable and rely on the token.

- **The watch URL carries the token as a query parameter.** This is necessary
  because browsers strip credentials from `user:pass@host` URLs. Query-string
  tokens can end up in browser history and server logs, so treat a `watch_url`
  with the same care as the rest of the token.

- **`cmd` in the exec API runs through a shell** (`bash -lc`) as the box's
  privileged user. That is by design — the whole point is SSH-equivalent
  access — but it means the token is a full remote-code-execution grant.

- **The hosted webapp (`webapp_url`) is public and unauthenticated by design.**
  It's a separate tunnel for serving your app to end users. Anything you place
  in `/srv/sidekick/www` is world-readable, and any executable in
  `/srv/sidekick/cgi-bin` runs per-request as the box's user with whatever the
  request supplies — so a buggy or injectable CGI script is an exposed
  remote-code path on the same box as your browser/session. You own the safety
  of what you deploy there; don't put secrets in the docroot, and validate CGI
  input. The `webapp_url` hostname is discoverable, so treat the webapp as
  internet-facing.

## Supported versions

This is an evolving project; only the latest `main` is supported. Pin a
specific image digest (`ghcr.io/eladb/sidekick@sha256:...`) if you need
reproducibility.
