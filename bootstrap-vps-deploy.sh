#!/usr/bin/env bash
# bootstrap-vps-deploy.sh — phase 2 of automated VPS bootstrap.
# Run as the deploy user (not root). Reads .bootstrap.env, clones the
# web-hub repo, runs install.sh, sets up Caddy reverse proxy, and
# configures the daily backup cron.
#
# Usage:
#   bash bootstrap-vps-deploy.sh
#   → if .bootstrap.env doesn't exist, writes a template and exits.
#   → fill in the template, then re-run.
#
# Idempotent — safe to re-run.

set -euo pipefail

ENV_FILE="${BOOTSTRAP_ENV_FILE:-$HOME/.bootstrap.env}"

# ── 0. preflight ──────────────────────────────────────
[[ $EUID -ne 0 ]] || { echo "ERROR: do not run as root. ssh in as the deploy user." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed. Did you run bootstrap-vps-root.sh first?" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not installed." >&2; exit 1; }

# ── 1. config template ────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'EOF'
# bootstrap-vps-deploy.sh config
# Fill in the values below, then re-run:  bash bootstrap-vps-deploy.sh

# ── REQUIRED ──────────────────────────────────────────
DOMAIN=                                                   # e.g. hub.acme-corp.com (must already DNS A-record to this VPS)

# ── REPO ACCESS ──────────────────────────────────────
# Default uses HTTPS public clone. For private repos, set up a deploy key
# (see ~/.ssh/) and switch to git@github.com:Lingo2018/web-hub.git
WEB_HUB_REPO=https://github.com/Lingo2018/web-hub.git

# ── OPTIONAL ─────────────────────────────────────────
DEPLOYMENT_YAML=                                          # e.g. deployments/acme-corp/deployment.yaml (after clone)
WEB_HUB_PORT=3800
DISCORD_WEBHOOK_URL=                                      # backup-failure alert webhook
BACKUP_ROOT=                                              # e.g. /tmp/web-hub-backup-staging or /mnt/nas/...
SKIP_CADDY=false                                          # true to skip Caddy reverse-proxy step
EOF
  chmod 600 "$ENV_FILE"
  echo "[deploy] created template $ENV_FILE"
  echo "[deploy] fill in DOMAIN (and optional fields), then re-run this script."
  exit 0
fi

# shellcheck source=/dev/null
. "$ENV_FILE"

# ── 2. validate ───────────────────────────────────────
[[ -n "${DOMAIN:-}" ]] || { echo "ERROR: DOMAIN required in $ENV_FILE" >&2; exit 1; }
[[ -n "${WEB_HUB_REPO:-}" ]] || { echo "ERROR: WEB_HUB_REPO required" >&2; exit 1; }
PORT="${WEB_HUB_PORT:-3800}"

# ── 3. clone repo ────────────────────────────────────
REPO_DIR="$HOME/web-hub"
if [[ ! -d "$REPO_DIR" ]]; then
  echo "[deploy] cloning $WEB_HUB_REPO into $REPO_DIR..."
  git clone "$WEB_HUB_REPO" "$REPO_DIR"
else
  echo "[deploy] $REPO_DIR exists, pulling latest..."
  git -C "$REPO_DIR" fetch --all
  git -C "$REPO_DIR" pull --ff-only origin master || echo "[deploy] WARN: pull failed (probably on a tag/branch); continuing"
fi
cd "$REPO_DIR"

# ── 4. run install.sh ────────────────────────────────
if [[ -n "${DEPLOYMENT_YAML:-}" ]]; then
  if [[ ! -f "$DEPLOYMENT_YAML" ]]; then
    echo "ERROR: DEPLOYMENT_YAML=$DEPLOYMENT_YAML does not exist" >&2
    exit 1
  fi
  ./scripts/install.sh "$DEPLOYMENT_YAML"
else
  ./scripts/install.sh
fi

# ── 5. Caddy reverse proxy + Let's Encrypt ───────────
if [[ "${SKIP_CADDY:-false}" != "true" ]]; then
  if ! command -v caddy >/dev/null 2>&1; then
    echo "[deploy] WARN: caddy not installed (root phase should have done this); skipping reverse-proxy"
  else
    echo "[deploy] configuring Caddy for $DOMAIN..."
    sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
$DOMAIN {
    reverse_proxy localhost:$PORT
}
EOF
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
    echo "[deploy] Caddy will auto-acquire LetsEncrypt cert for $DOMAIN within 30-60s"
  fi
fi

# ── 6. backup cron ───────────────────────────────────
if [[ -n "${BACKUP_ROOT:-}" ]]; then
  mkdir -p "$HOME/.config/web-hub" "$REPO_DIR/logs"
  cat > "$HOME/.config/web-hub/backup.env" <<EOF
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL:-}
EOF
  chmod 600 "$HOME/.config/web-hub/backup.env"

  CRON_LINE="30 17 * * * BACKUP_ROOT=$BACKUP_ROOT BACKUP_ENV_FILE=$HOME/.config/web-hub/backup.env $REPO_DIR/scripts/full-backup.sh >> $REPO_DIR/logs/full-backup.log 2>&1"
  # Replace any previous full-backup.sh cron line
  ( crontab -l 2>/dev/null | grep -v 'full-backup.sh' ; echo "$CRON_LINE" ) | crontab -
  echo "[deploy] daily backup cron installed (UTC 17:30 = Beijing 01:30 next day)"
  echo "[deploy] backup env: $HOME/.config/web-hub/backup.env"
fi

# ── 7. handoff ───────────────────────────────────────
echo ""
echo "================================================================"
echo " ✓ web-hub deployed"
echo ""
if [[ "${SKIP_CADDY:-false}" != "true" ]]; then
  echo "   URL:        https://$DOMAIN"
  echo "   (or local) http://localhost:$PORT"
else
  echo "   URL:        http://localhost:$PORT (Caddy skipped — set up reverse proxy yourself)"
fi
echo "   Login:      admin / admin123"
echo "   ⚠ CHANGE PASSWORD NOW: /settings → 修改密码"
echo ""
echo "   Logs:       cd $REPO_DIR && docker compose logs -f"
echo "   Update:     cd $REPO_DIR && ./scripts/update.sh"
echo "   Rollback:   cd $REPO_DIR && ./scripts/rollback.sh"
echo "   Backup:     cron installed (if BACKUP_ROOT was set)"
echo "================================================================"
