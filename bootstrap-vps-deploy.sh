#!/usr/bin/env bash
# bootstrap-vps-deploy.sh — phase 2 of automated VPS bootstrap.
# Run as the deploy user (not root). One-liner deploy:
#
#   DOMAIN=hub.acme.com bash <(curl -fsSL <raw url>)
#
# Or interactive (will prompt for required + optional values):
#
#   bash <(curl -fsSL <raw url>)
#
# Re-running with an existing ~/.bootstrap.env is silent (no prompts,
# uses the saved values) — fully idempotent.

set -euo pipefail

ENV_FILE="${BOOTSTRAP_ENV_FILE:-$HOME/.bootstrap.env}"

# ── 0. preflight ──────────────────────────────────────
[[ $EUID -ne 0 ]] || { echo "ERROR: do not run as root. ssh in as the deploy user." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not installed. Run bootstrap-vps-root.sh first." >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not installed." >&2; exit 1; }

# ── 1. load existing env file (if any) ────────────────
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  . "$ENV_FILE"
fi

# ── 2. prompt missing values from /dev/tty (works under bash <(curl)) ──
have_tty() {
  # `[[ -t 0 ]]` is the canonical "is stdin a terminal" check; works
  # cleanly under `set -euo pipefail` without leaking redirection
  # errors to stderr like the older `exec 3</dev/tty` probe did.
  [[ -t 0 ]]
}

prompt_required() {
  local name="$1"
  local desc="$2"
  local current=""
  # bash 5 + `set -u` rejects ${!name:-} when target is unset; use [[ -v ]]
  if [[ -v "$name" ]]; then current="${!name}"; fi
  if [[ -z "$current" ]]; then
    if have_tty; then
      read -rp "$desc: " current </dev/tty || true
    fi
    [[ -n "$current" ]] || {
      echo "ERROR: $name required (set as env var or run interactively)" >&2
      exit 1
    }
    printf -v "$name" '%s' "$current"
  fi
}

prompt_optional() {
  local name="$1"
  local desc="$2"
  local default="${3:-}"
  local current=""
  if [[ -v "$name" ]]; then current="${!name}"; fi
  if [[ -z "$current" ]] && have_tty; then
    if [[ -n "$default" ]]; then
      read -rp "$desc [$default]: " current </dev/tty || true
      current="${current:-$default}"
    else
      read -rp "$desc (ENTER to skip): " current </dev/tty || true
    fi
    printf -v "$name" '%s' "$current"
  elif [[ -z "$current" ]] && [[ -n "$default" ]]; then
    printf -v "$name" '%s' "$default"
  fi
}

echo "[deploy] gathering config (env var > $ENV_FILE > prompt)..."
prompt_required DOMAIN          "Domain (e.g. hub.acme.com — must already DNS A-record to this VPS)"
prompt_optional WEB_HUB_REPO    "Web Hub git repo URL (only needed if running this script standalone — operator-led deploy-to-vps.sh pre-uploads source)"
prompt_optional WEB_HUB_PORT    "Web Hub local port"             "3800"
prompt_optional DEPLOYMENT_YAML "Branding seed file path (in repo)"
prompt_optional DISCORD_WEBHOOK_URL "Discord webhook for backup-failure alerts"
prompt_optional BACKUP_ROOT     "Backup output dir (e.g. /tmp/web-hub-backup-staging)"
prompt_optional SKIP_CADDY      "Skip Caddy reverse-proxy step? (true/false)" "false"

# ── 3. persist for next time ──────────────────────────
cat > "$ENV_FILE" <<EOF
# Auto-saved by bootstrap-vps-deploy.sh — re-runs are silent.
DOMAIN=$DOMAIN
WEB_HUB_REPO=$WEB_HUB_REPO
WEB_HUB_PORT=$WEB_HUB_PORT
DEPLOYMENT_YAML=${DEPLOYMENT_YAML:-}
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL:-}
BACKUP_ROOT=${BACKUP_ROOT:-}
SKIP_CADDY=$SKIP_CADDY
EOF
chmod 600 "$ENV_FILE"
echo "[deploy] saved config to $ENV_FILE"

# ── 4. obtain repo (clone if missing, pull if .git present, skip if pre-uploaded) ──
REPO_DIR="$HOME/web-hub"
if [[ -d "$REPO_DIR/server" && -d "$REPO_DIR/scripts" ]]; then
  if [[ -d "$REPO_DIR/.git" ]]; then
    echo "[deploy] $REPO_DIR exists with .git, pulling latest..."
    git -C "$REPO_DIR" fetch --all --tags 2>/dev/null || true
    git -C "$REPO_DIR" pull --ff-only origin master 2>/dev/null \
      || echo "[deploy] WARN: pull failed (private repo, no auth, or on a tag); continuing"
  else
    echo "[deploy] $REPO_DIR exists (uploaded by deploy-to-vps.sh, no .git); skipping pull"
  fi
elif [[ ! -d "$REPO_DIR" ]]; then
  if [[ -z "${WEB_HUB_REPO:-}" ]]; then
    cat >&2 <<EOF
[deploy] ERROR: $REPO_DIR is empty AND WEB_HUB_REPO is not set.

This script needs source code to install. Two ways to get it there:

  (recommended) Operator-led — from the operator's laptop:
    cd ~/projects/web-hub
    ./scripts/deploy-to-vps.sh root@<this-vps-ip> <domain>
  This tar-uploads the source over ssh so this script skips clone.

  (advanced) Manual clone — set WEB_HUB_REPO to a URL the VPS can read:
    - SSH deploy-key URL: git@github.com:Lingo2018/web-hub.git
      (requires the VPS's pubkey added under repo Settings → Deploy keys)
    - PAT-embedded URL: https://x-access-token:<TOKEN>@github.com/Lingo2018/web-hub.git
      (warning: token persists in ~/web-hub/.git/config in plain text)

  NOTE: Lingo2018/web-hub-bootstrap is the public mirror of THIS script
  only — it does NOT contain the full app source. You can't clone the
  bootstrap repo and expect install.sh to find server/, vendor/, etc.
EOF
    exit 1
  fi
  echo "[deploy] cloning $WEB_HUB_REPO into $REPO_DIR..."
  git clone "$WEB_HUB_REPO" "$REPO_DIR"
fi
cd "$REPO_DIR"

# ── 5. run install.sh ────────────────────────────────
if [[ -n "${DEPLOYMENT_YAML:-}" ]]; then
  if [[ ! -f "$DEPLOYMENT_YAML" ]]; then
    echo "ERROR: DEPLOYMENT_YAML=$DEPLOYMENT_YAML does not exist" >&2
    exit 1
  fi
  ./scripts/install.sh "$DEPLOYMENT_YAML"
else
  ./scripts/install.sh
fi

# ── 6. Caddy reverse proxy + Let's Encrypt ───────────
if [[ "${SKIP_CADDY:-false}" != "true" ]]; then
  if ! command -v caddy >/dev/null 2>&1; then
    echo "[deploy] WARN: caddy not installed (root phase should have done this); skipping reverse-proxy"
  else
    echo "[deploy] configuring Caddy for $DOMAIN..."
    sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
$DOMAIN {
    reverse_proxy localhost:$WEB_HUB_PORT
}
EOF
    sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy
    echo "[deploy] Caddy will auto-acquire LetsEncrypt cert for $DOMAIN within 30-60s"
  fi
fi

# ── 7. backup cron ───────────────────────────────────
if [[ -n "${BACKUP_ROOT:-}" ]]; then
  mkdir -p "$HOME/.config/web-hub" "$REPO_DIR/logs"
  cat > "$HOME/.config/web-hub/backup.env" <<EOF
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL:-}
EOF
  chmod 600 "$HOME/.config/web-hub/backup.env"

  CRON_LINE="30 17 * * * BACKUP_ROOT=$BACKUP_ROOT BACKUP_ENV_FILE=$HOME/.config/web-hub/backup.env $REPO_DIR/scripts/full-backup.sh >> $REPO_DIR/logs/full-backup.log 2>&1"
  ( crontab -l 2>/dev/null | grep -v 'full-backup.sh' ; echo "$CRON_LINE" ) | crontab -
  echo "[deploy] daily backup cron installed (UTC 17:30 = Beijing 01:30 next day)"
fi

# ── 8. handoff ───────────────────────────────────────
echo ""
echo "================================================================"
echo " ✓ web-hub deployed"
echo ""
if [[ "${SKIP_CADDY:-false}" != "true" ]]; then
  echo "   URL:        https://$DOMAIN"
  echo "   (or local) http://localhost:$WEB_HUB_PORT"
else
  echo "   URL:        http://localhost:$WEB_HUB_PORT (Caddy skipped)"
fi
echo "   Login:      admin / admin123"
echo "   ⚠ CHANGE PASSWORD NOW: /settings → 修改密码"
echo ""
echo "   Logs:       cd $REPO_DIR && docker compose logs -f"
if [[ -d "$REPO_DIR/.git" ]]; then
  echo "   Update:     cd $REPO_DIR && ./scripts/update.sh"
  echo "   Rollback:   cd $REPO_DIR && ./scripts/rollback.sh"
else
  echo "   Update:     re-run scripts/deploy-to-vps.sh from operator laptop"
  echo "                (this VPS was provisioned via tar+ssh source upload, no .git here,"
  echo "                 so the in-VPS update.sh / rollback.sh paths will fail)"
fi
echo "================================================================"
