#!/usr/bin/env bash
# setup-server.sh
# Configures nginx (and optionally Node.js + PM2) for a site on the server.
# Auto-detects domain from nginx/*.conf and app type from package.json.
#
# Usage: sudo bash setup-server.sh [site-dir] [--skip-certbot]
#   site-dir      Path to the cloned site repo (default: current directory)
#   --skip-certbot  Skip SSL certificate issuance
#
# Example:
#   cd /path/to/site-repo && sudo bash /path/to/infra/scripts/setup-server.sh
#   sudo bash /path/to/infra/scripts/setup-server.sh /path/to/site-repo

set -euo pipefail

NODE_MIN_VERSION=20

# ── Parse args ────────────────────────────────────────────────────────────────

SITE_DIR=""
SKIP_CERTBOT=false

for arg in "$@"; do
  case "$arg" in
    --skip-certbot) SKIP_CERTBOT=true ;;
    -*) echo "[WARN]  Unknown flag: $arg" ;;
    *) SITE_DIR="$arg" ;;
  esac
done

SITE_DIR="${SITE_DIR:-$(pwd)}"
SITE_DIR="$(cd "$SITE_DIR" && pwd)"
NGINX_DIR="${SITE_DIR}/nginx"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "$EUID" -eq 0 ]] || error "Please run with sudo: sudo bash $0 $*"
}

# ── Auto-detect domain from nginx conf ───────────────────────────────────────

detect_domain() {
  local conf
  conf="$(ls "${NGINX_DIR}/"*.conf 2>/dev/null | grep -v 'default\|snippet' | head -1)"
  [[ -n "$conf" ]] || error "No nginx *.conf found in ${NGINX_DIR}/ — cannot detect domain"
  basename "$conf" .conf
}

# ── Auto-detect app type ──────────────────────────────────────────────────────

is_nodejs_app() {
  [[ -f "${SITE_DIR}/package.json" ]] || [[ -f "${SITE_DIR}/ecosystem.config.js" ]]
}

DOMAIN="$(detect_domain)"
WWW_ROOT="/var/www/${DOMAIN}"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}"
CONF_SOURCE="${NGINX_DIR}/${DOMAIN}.conf"

# ── Steps ─────────────────────────────────────────────────────────────────────

ensure_node() {
  if command -v node &>/dev/null; then
    local version
    version="$(node -e 'process.stdout.write(process.versions.node.split(".")[0])')"
    if [[ "$version" -ge "$NODE_MIN_VERSION" ]]; then
      success "Node.js ${version} already installed"
      return
    fi
    warn "Node.js ${version} is below minimum (${NODE_MIN_VERSION}) — upgrading..."
  else
    info "Node.js not found — installing..."
  fi

  curl -fsSL https://deb.nodesource.com/setup_${NODE_MIN_VERSION}.x | bash -
  apt-get install -y nodejs
  success "Node.js $(node --version) installed"
}

ensure_pm2() {
  if command -v pm2 &>/dev/null; then
    success "PM2 already installed ($(pm2 --version))"
  else
    info "Installing PM2..."
    npm install -g pm2
    success "PM2 $(pm2 --version) installed"
  fi
}

create_web_root() {
  if [[ -d "$WWW_ROOT" ]]; then
    info "Web root already exists: ${WWW_ROOT}"
  else
    mkdir -p "$WWW_ROOT"
    success "Created web root: ${WWW_ROOT}"
  fi
}

install_nginx_conf() {
  [[ -f "$CONF_SOURCE" ]] || error "nginx config not found at: ${CONF_SOURCE}"

  cp "$CONF_SOURCE" "$NGINX_CONF"
  success "Copied nginx config to ${NGINX_CONF}"

  if [[ -L "$NGINX_ENABLED" ]]; then
    info "Site already enabled: ${NGINX_ENABLED}"
  else
    ln -s "$NGINX_CONF" "$NGINX_ENABLED"
    success "Enabled site: ${NGINX_ENABLED}"
  fi
}

test_and_reload_nginx() {
  nginx -t || error "nginx config test failed — aborting reload"
  systemctl reload nginx
  success "nginx reloaded"
}

run_certbot() {
  if [[ "$SKIP_CERTBOT" == true ]]; then
    info "Skipping certbot (--skip-certbot passed)"
    return
  fi

  command -v certbot &>/dev/null || error "certbot not found — install it: sudo apt install certbot python3-certbot-nginx"

  echo ""
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  warn "CLOUDFLARE DNS: Before continuing, make sure the DNS record for"
  warn "${DOMAIN} is set to 'DNS only' (grey cloud, NOT orange/proxied)"
  warn "in Cloudflare. Certbot's HTTP challenge will fail if the proxy"
  warn "is active before HTTPS is configured. Re-enable the proxy after"
  warn "certbot completes successfully."
  warn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  read -rp "Press Enter when Cloudflare DNS is set to 'DNS only', or Ctrl+C to abort..."

  info "Running certbot for ${DOMAIN} ..."
  certbot --nginx -d "$DOMAIN"
  success "SSL certificate issued and nginx updated"

  echo ""
  info "You can now re-enable the Cloudflare proxy (orange cloud) for ${DOMAIN}"
}

verify_static() {
  test -f "${WWW_ROOT}/index.html" \
    && success "index.html present in web root" \
    || info "Web root is empty — deploy will populate it via GitHub Actions"
}

verify_nodejs() {
  command -v pm2 &>/dev/null \
    && success "PM2 $(pm2 --version) is installed" \
    || warn "PM2 not found — check ensure_pm2 step"

  command -v node &>/dev/null \
    && success "Node.js $(node --version) is installed" \
    || warn "Node.js not found"

  info "Web root: ${WWW_ROOT}"
  info "First deploy will run: npm ci && npm run build && pm2 start ecosystem.config.js"
}

# ── Main ──────────────────────────────────────────────────────────────────────

require_root
info "Site directory: ${SITE_DIR}"
info "Domain detected: ${DOMAIN}"

if is_nodejs_app; then
  info "App type: Node.js (package.json or ecosystem.config.js found)"
else
  info "App type: Static site"
fi
echo ""

if is_nodejs_app; then
  ensure_node
  ensure_pm2
fi

create_web_root
install_nginx_conf
test_and_reload_nginx
run_certbot

if is_nodejs_app; then
  verify_nodejs
else
  verify_static
fi

echo ""
success "Setup complete for ${DOMAIN}"
info "Next steps:"
info "  1. Ensure DNS A record for ${DOMAIN} points to this server's IP"
info "  2. Run: bash /path/to/infra/scripts/set-secrets.sh ${SITE_DIR}"
info "  3. Push to main — the deploy workflow will handle the rest"
