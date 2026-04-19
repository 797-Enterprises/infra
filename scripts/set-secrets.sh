#!/usr/bin/env bash
# set-secrets.sh
# Creates a dedicated deploy user (if needed), generates a deploy key,
# authorizes it, grants web-root ownership, and seeds GitHub Actions secrets.
# Auto-detects domain (from nginx/*.conf), repo (from git remote), and app
# type (from package.json / ecosystem.config.js).
#
# Usage: bash set-secrets.sh [site-dir]
#   site-dir  Path to the cloned site repo (default: current directory)
#
# Example:
#   cd /path/to/site-repo && bash /path/to/infra/scripts/set-secrets.sh
#   bash /path/to/infra/scripts/set-secrets.sh /path/to/site-repo

set -euo pipefail

DEPLOY_USER_DEFAULT="deploy"

# ── Parse args ────────────────────────────────────────────────────────────────

SITE_DIR="${1:-$(pwd)}"
SITE_DIR="$(cd "$SITE_DIR" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
error()   { echo "[ERROR] $*" >&2; exit 1; }

# ── Auto-detect domain, repo, and app type ────────────────────────────────────

detect_domain() {
  local conf
  conf="$(ls "${SITE_DIR}/nginx/"*.conf 2>/dev/null | grep -v 'default\|snippet' | head -1)"
  [[ -n "$conf" ]] || error "No nginx *.conf found in ${SITE_DIR}/nginx/ — cannot detect domain"
  basename "$conf" .conf
}

detect_repo() {
  git -C "$SITE_DIR" remote get-url origin 2>/dev/null \
    | sed 's|https://github.com/||;s|git@github.com:||;s|\.git$||'
}

is_nodejs_app() {
  [[ -f "${SITE_DIR}/package.json" ]] || [[ -f "${SITE_DIR}/ecosystem.config.js" ]]
}

DOMAIN="$(detect_domain)"
DOMAIN_SLUG="${DOMAIN//./_}"
WWW_ROOT="/var/www/${DOMAIN}"
REPO="$(detect_repo)"

# ── Preflight ─────────────────────────────────────────────────────────────────

command -v gh &>/dev/null || error "gh CLI not found — install it: sudo apt install gh"
gh auth status &>/dev/null || error "Not authenticated — run: gh auth login"

echo ""
info "Site directory: ${SITE_DIR}"
info "Domain: ${DOMAIN}"
info "Repo:   ${REPO}"
if is_nodejs_app; then
  info "App type: Node.js"
else
  info "App type: Static site"
fi
echo ""

# ── Pick deploy user ──────────────────────────────────────────────────────────

read -rp "SSH user to use for deploys [${DEPLOY_USER_DEFAULT}]: " SSH_USER
SSH_USER="${SSH_USER:-$DEPLOY_USER_DEFAULT}"

DEPLOY_KEY="$HOME/.ssh/deploy_key_${DOMAIN_SLUG}_${SSH_USER}"

# ── Create deploy user if needed ──────────────────────────────────────────────

if id "$SSH_USER" &>/dev/null; then
  info "User '${SSH_USER}' already exists"
else
  info "Creating user '${SSH_USER}'..."
  sudo useradd -m -s /bin/bash "$SSH_USER"
  success "Created user '${SSH_USER}'"
fi

USER_HOME="$(getent passwd "$SSH_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || error "Could not resolve home directory for ${SSH_USER}"

# ── Ensure .ssh dir exists for deploy user ────────────────────────────────────

sudo mkdir -p "${USER_HOME}/.ssh"
sudo chmod 700 "${USER_HOME}/.ssh"
sudo chown "${SSH_USER}:${SSH_USER}" "${USER_HOME}/.ssh"

# ── Generate deploy key ───────────────────────────────────────────────────────

if [[ -f "$DEPLOY_KEY" ]]; then
  info "Deploy key already exists: ${DEPLOY_KEY}"
  read -rp "Regenerate it? [y/N]: " regen
  if [[ "${regen,,}" == "y" ]]; then
    rm -f "$DEPLOY_KEY" "${DEPLOY_KEY}.pub"
    ssh-keygen -t ed25519 -C "github-actions@${DOMAIN}" -f "$DEPLOY_KEY" -N ""
    success "Generated new deploy key: ${DEPLOY_KEY}"
  fi
else
  ssh-keygen -t ed25519 -C "github-actions@${DOMAIN}" -f "$DEPLOY_KEY" -N ""
  success "Generated deploy key: ${DEPLOY_KEY}"
fi

# ── Authorize public key on the deploy user ───────────────────────────────────

PUB_KEY="$(cat "${DEPLOY_KEY}.pub")"
AUTH_KEYS="${USER_HOME}/.ssh/authorized_keys"

if sudo test -f "$AUTH_KEYS" && sudo grep -qF "$PUB_KEY" "$AUTH_KEYS"; then
  info "Public key already in ${AUTH_KEYS}"
else
  echo "$PUB_KEY" | sudo tee -a "$AUTH_KEYS" > /dev/null
  sudo chmod 600 "$AUTH_KEYS"
  sudo chown "${SSH_USER}:${SSH_USER}" "$AUTH_KEYS"
  success "Added public key to ${AUTH_KEYS}"
fi

# ── Grant web-root ownership ──────────────────────────────────────────────────

if [[ -d "$WWW_ROOT" ]]; then
  sudo chown -R "${SSH_USER}:${SSH_USER}" "$WWW_ROOT"
  success "Granted ${SSH_USER} ownership of ${WWW_ROOT}"
else
  info "Web root does not exist yet (${WWW_ROOT}) — run setup-server.sh first"
fi

# ── Node.js: write env vars and set up PM2 startup ───────────────────────────

if is_nodejs_app; then
  ENV_FILE="${WWW_ROOT}/.env.production"

  echo ""
  info "Node.js app detected — configuring runtime environment..."

  read -rp "ANTHROPIC_API_KEY (leave blank to skip): " ANTHROPIC_API_KEY
  if [[ -n "$ANTHROPIC_API_KEY" ]]; then
    if sudo test -f "$ENV_FILE" && sudo grep -q "ANTHROPIC_API_KEY" "$ENV_FILE"; then
      info ".env.production already contains ANTHROPIC_API_KEY — updating..."
      sudo sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "$ENV_FILE"
    else
      echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" | sudo tee -a "$ENV_FILE" > /dev/null
    fi
    sudo chown "${SSH_USER}:${SSH_USER}" "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"
    success "Written ANTHROPIC_API_KEY to ${ENV_FILE}"
  else
    info "Skipping ANTHROPIC_API_KEY — add it manually to ${ENV_FILE} if needed"
  fi

  info "Configuring PM2 startup for user '${SSH_USER}'..."
  PM2_STARTUP="$(sudo -u "$SSH_USER" pm2 startup systemd -u "$SSH_USER" --hp "$USER_HOME" 2>&1 | grep 'sudo' | head -1 || true)"
  if [[ -n "$PM2_STARTUP" ]]; then
    eval "$PM2_STARTUP"
    success "PM2 startup configured for ${SSH_USER}"
  else
    info "PM2 startup already configured (or run manually: pm2 startup)"
  fi
fi

# ── Set GitHub secrets ────────────────────────────────────────────────────────

set_secret() {
  gh secret set "$1" --repo "$REPO" --body "$2"
  success "Set GitHub secret: $1"
}

echo ""
set_secret "SSH_PRIVATE_KEY" "$(cat "$DEPLOY_KEY")"
set_secret "SSH_USER" "$SSH_USER"

DETECTED_IP="$(curl -sf https://checkip.amazonaws.com || true)"
if [[ -n "$DETECTED_IP" ]]; then
  info "Detected server IP: ${DETECTED_IP}"
  read -rp "Use this IP? [Y/n]: " use_ip
  if [[ "${use_ip,,}" == "n" ]]; then
    read -rp "Server IP: " DETECTED_IP
  fi
else
  read -rp "Server IP (SSH_HOST): " DETECTED_IP
fi
[[ -n "$DETECTED_IP" ]] || error "SSH_HOST cannot be empty"
set_secret "SSH_HOST" "$DETECTED_IP"

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
success "All secrets set on ${REPO}"
info "Deploy user: ${SSH_USER}"
info "Deploy key:  ${DEPLOY_KEY}"
info "Trigger a deploy by pushing to main, or:"
info "  gh workflow run deploy.yml --repo ${REPO}"
