# Contributing

Thanks for your interest in sidekick! This is a small, script-driven project —
contributions are welcome via pull request.

## Workflow

1. Fork and branch off `main`.
2. Make your change, keeping it focused.
3. Open a PR describing what changed and how you verified it.

## The shape of the code

Everything is deliberately plain and dependency-light:

- **`provision.sh`** installs the software (apt + a couple of upstream release
  binaries). It takes **no secrets** and must stay idempotent and safe to re-run.
- **`configure-and-start.sh`** renders the runtime config from the secrets
  (`AUTH_TOKEN`/`SERVER_ID`) and starts supervisord. This is the only place
  secrets are consumed.
- **`scripts/platforms/*.sh`** are thin per-platform installers that share
  helpers in `scripts/lib/common.sh`. They deploy the box, discover its tunnel
  URL, and print the token — nothing platform-specific leaks into `common.sh`.
- The **`Dockerfile`** bakes `provision.sh` at build time; GitHub Actions
  publishes the image to `ghcr.io/eladb/sidekick`. Container platforms (fly.io,
  Docker) pull that image; bare-VM platforms (EC2, Hetzner) run `provision.sh`
  from source at boot. Keep both paths working when you touch shared files.

See the "Architecture" section of the README for the full picture.

## Style & checks

- Shell scripts target **bash**; run `shellcheck` and `bash -n` on anything you
  change and match the surrounding style (comments explaining the *why*).
- Changes to image inputs (`Dockerfile`, `provision.sh`, `configure-and-start.sh`,
  the templates, `services/**`, `scripts/tunnel-watcher.sh`) trigger the image
  publish workflow — keep the Dockerfile build green.

## Verifying a change

There's no unit-test harness; the meaningful test is a real deploy. If your
change touches a platform path, deploy to that platform (`scripts/install.sh
--platform <p>`) and confirm the box comes up: the token prints, `/healthz`
returns 200, and the browser/CDP + watch view work. Note in your PR which
platform(s) you exercised.

## Security

- **Never commit secrets.** The token (`sidekick-token.txt`), `.env`, and keys
  are gitignored; keep them that way.
- Report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md).
