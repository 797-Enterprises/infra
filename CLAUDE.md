# Infra repo — Claude context

Shared deployment infrastructure for all 797 Enterprises sites on AWS Lightsail + nginx.

## What lives here

| Path | Purpose |
|---|---|
| `.github/workflows/deploy-static-site.yml` | Reusable workflow — rsync static files to server |
| `.github/workflows/deploy-nodejs-app.yml` | Reusable workflow — rsync source, build on server, PM2 |
| `scripts/setup-server.sh` | One-time server setup: nginx, certbot, Node.js, PM2 |
| `scripts/set-secrets.sh` | Deploy user, SSH key, GitHub secrets, .env.production |
| `README.md` | Full step-by-step docs for adding new sites |

## Key conventions

- Scripts auto-detect domain from `site-repo/nginx/*.conf` (filename = domain)
- Scripts auto-detect app type from presence of `package.json` / `ecosystem.config.js`
- Scripts accept an optional `site-dir` argument (default: `pwd`)
- Each site repo contains only site-specific files: `nginx/domain.conf`, `ecosystem.config.js` (Node.js only), `deploy.yml` calling the infra reusable workflow
- `.env.production` is written to the server by `set-secrets.sh` — never committed to any site repo
- PM2 port assignments are tracked in `README.md` port registry — pick the next available port when adding a Node.js site

## Sites using this infra

| Domain | Repo | Workflow | PM2 port |
|---|---|---|---|
| 797enterprises.com | 797-Enterprises/797Enterprises_vNext | deploy-static-site | — |
| chicityevents.com | swschmidt/chicityevents_vnext | deploy-static-site | — |
| moviebot.797enterprises.com | swschmidt/MovieBot | deploy-nodejs-app | 3010 |

## Adding a new site

See `README.md` for full steps. Short version:
1. Create site repo with `nginx/domain.conf` + `deploy.yml` (+ `ecosystem.config.js` if Node.js)
2. On server: `sudo bash scripts/setup-server.sh /tmp/site-repo`
3. On server: `bash scripts/set-secrets.sh /tmp/site-repo`
4. Push to main
5. If Node.js: add port to the registry in `README.md`
