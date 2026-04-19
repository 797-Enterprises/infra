# 797 Enterprises — Infrastructure

Shared deployment infrastructure for all 797 Enterprises sites hosted on AWS Lightsail + nginx.

## Reusable workflows

| Workflow | Use for |
|---|---|
| `deploy-static-site.yml` | Pure HTML/CSS/JS sites — rsync files directly to web root |
| `deploy-nodejs-app.yml` | Next.js / Node.js apps — rsync source, build on server, manage via PM2 |

## Scripts

Both scripts live in this repo and work with any site repo. They auto-detect the domain from `nginx/*.conf` and the app type from `package.json` / `ecosystem.config.js`.

| Script | Run as | Purpose |
|---|---|---|
| `scripts/setup-server.sh` | `sudo` | One-time server setup: nginx config, certbot SSL, Node.js + PM2 (if Node.js app) |
| `scripts/set-secrets.sh` | current user | Deploy user, SSH key, GitHub Actions secrets, `.env.production` (if Node.js app) |

---

## Deploying a new site

### Step 0 — Prerequisites (one-time per server)

```bash
sudo apt update && sudo apt install -y nginx certbot python3-certbot-nginx gh rsync
```

---

### Option A — Static site (HTML/CSS/JS, no build step)

#### 1. Create the site repo

Required structure:
```
nginx/
  yourdomain.com.conf     ← nginx server block (port 80 only; certbot adds SSL)
.github/
  workflows/
    deploy.yml
```

**`nginx/yourdomain.com.conf`** — minimal static site config:
```nginx
server {
    listen 80;
    listen [::]:80;
    server_name yourdomain.com www.yourdomain.com;

    root /var/www/yourdomain.com;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location ~* \.(css|js|png|jpg|jpeg|webp|ico|gif|svg|woff|woff2|ttf)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    gzip on;
    gzip_types text/css text/plain application/json image/svg+xml;
}
```

**`.github/workflows/deploy.yml`**:
```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: 797-Enterprises/infra/.github/workflows/deploy-static-site.yml@main
    with:
      source_path: ./          # or ./site/ if your HTML lives in a subdirectory
      remote_path: /var/www/yourdomain.com/
      purge_cloudflare: true   # set false if not using Cloudflare
    secrets:
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      SSH_HOST: ${{ secrets.SSH_HOST }}
      SSH_USER: ${{ secrets.SSH_USER }}
      CF_ZONE_ID: ${{ secrets.CF_ZONE_ID }}
      CF_API_TOKEN: ${{ secrets.CF_API_TOKEN }}
```

---

### Option B — Node.js / Next.js app

#### 1. Create the site repo

Required structure:
```
nginx/
  yourdomain.com.conf     ← nginx reverse proxy config
ecosystem.config.js       ← PM2 process config
package.json
.github/
  workflows/
    deploy.yml
```

**`nginx/yourdomain.com.conf`** — reverse proxy config:
```nginx
server {
    listen 80;
    server_name yourdomain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name yourdomain.com;

    # SSL managed by certbot
    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    location / {
        proxy_pass         http://127.0.0.1:PORT;   # ← match PORT in ecosystem.config.js
        proxy_http_version 1.1;
        proxy_set_header   Upgrade $http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
        proxy_buffering    off;     # required for streaming responses (SSE, etc.)
        proxy_read_timeout 300s;
    }
}
```

**`ecosystem.config.js`**:
```js
module.exports = {
  apps: [
    {
      name: "your-app-name",   // ← used as pm2_app_name in deploy.yml
      script: "node_modules/.bin/next",
      args: "start",
      cwd: "/var/www/yourdomain.com",
      instances: 1,
      autorestart: true,
      watch: false,
      env: {
        NODE_ENV: "production",
        PORT: 3010,             // ← pick a unique port per site
      },
    },
  ],
};
```

**`.github/workflows/deploy.yml`**:
```yaml
name: Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: 797-Enterprises/infra/.github/workflows/deploy-nodejs-app.yml@main
    with:
      remote_path: /var/www/yourdomain.com/
      pm2_app_name: your-app-name   # ← must match name in ecosystem.config.js
    secrets:
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      SSH_HOST: ${{ secrets.SSH_HOST }}
      SSH_USER: ${{ secrets.SSH_USER }}
```

---

### Step 2 — Clone your site repo on the server and run setup

```bash
# SSH into the server
ssh user@your-server-ip

# Clone the infra repo (if not already present)
git clone https://github.com/797-Enterprises/infra.git ~/infra

# Clone your site repo somewhere temporary (just to run the scripts)
git clone https://github.com/your-org/your-site-repo.git /tmp/site

# Run server setup (auto-detects domain and app type)
sudo bash ~/infra/scripts/setup-server.sh /tmp/site

# Run secrets setup (sets SSH key + GitHub Actions secrets)
bash ~/infra/scripts/set-secrets.sh /tmp/site

# Clean up the temporary clone
rm -rf /tmp/site
```

> **Cloudflare DNS:** `setup-server.sh` will remind you interactively, but note it here too:
> Before certbot runs, set the DNS record for your domain to **"DNS only" (grey cloud)**
> in Cloudflare. Certbot's HTTP challenge fails when Cloudflare proxying is active and
> the site doesn't have a valid cert yet. Re-enable the proxy (orange cloud) after certbot
> finishes.

---

### Step 3 — Push to main

The GitHub Actions workflow triggers automatically. For a Node.js app the first deploy will:
1. Rsync source to `/var/www/yourdomain.com/`
2. Run `npm ci && npm run build`
3. Start the app with `pm2 start ecosystem.config.js`

Subsequent pushes restart the existing PM2 process.

---

## Existing sites

| Site | Repo | Type |
|---|---|---|
| 797enterprises.com | [797-Enterprises/797Enterprises_vNext](https://github.com/797-Enterprises/797Enterprises_vNext) | Static |
| chicityevents.com | [swschmidt/chicityevents_vnext](https://github.com/swschmidt/chicityevents_vnext) | Static |
| moviebot.797enterprises.com | [swschmidt/MovieBot](https://github.com/swschmidt/MovieBot) | Next.js (Node.js) |

---

## Port registry

Keep this updated to avoid port conflicts between Node.js apps.

| Port | Site |
|---|---|
| 3010 | moviebot.797enterprises.com |
