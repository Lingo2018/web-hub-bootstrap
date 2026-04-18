#!/usr/bin/env bash
# bootstrap-vps-root.sh — phase 1 of automated VPS bootstrap.
# Run as root. Creates the deploy user, hardens SSH, installs all
# system-level deps. After this, ssh in as the deploy user and run
# bootstrap-vps-deploy.sh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Lingo2018/web-hub/master/scripts/bootstrap-vps-root.sh \
#     | SSH_PUBKEY="ssh-ed25519 AAAA..." bash
#
#   OR scp this file to /tmp on the VPS, then:
#   SSH_PUBKEY="ssh-ed25519 AAAA..." bash /tmp/bootstrap-vps-root.sh
#
# Idempotent — safe to re-run if something fails midway.

set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-deploy}"
SSH_PUBKEY="${SSH_PUBKEY:-}"

# ── preflight ──────────────────────────────────────────
[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root" >&2; exit 1; }
if [[ -z "$SSH_PUBKEY" ]]; then
  echo "ERROR: SSH_PUBKEY env var required. Pass your ed25519 / rsa pubkey:" >&2
  echo "  SSH_PUBKEY=\"\$(cat ~/.ssh/id_ed25519.pub)\" bash $0" >&2
  exit 1
fi

# ── 1. deploy user + sudo ─────────────────────────────
if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  echo "[root] created user $DEPLOY_USER"
else
  echo "[root] user $DEPLOY_USER already exists, skipping creation"
fi
usermod -aG sudo "$DEPLOY_USER"

# Passwordless sudo for deploy (so deploy phase can run apt without a password)
SUDOERS_FILE="/etc/sudoers.d/$DEPLOY_USER"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "$DEPLOY_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
  chmod 440 "$SUDOERS_FILE"
  echo "[root] enabled passwordless sudo for $DEPLOY_USER"
fi

# ── 2. SSH key ─────────────────────────────────────────
DEPLOY_HOME=$(eval echo "~$DEPLOY_USER")
mkdir -p "$DEPLOY_HOME/.ssh"
touch "$DEPLOY_HOME/.ssh/authorized_keys"
# Append + dedup
if ! grep -qxF "$SSH_PUBKEY" "$DEPLOY_HOME/.ssh/authorized_keys"; then
  echo "$SSH_PUBKEY" >> "$DEPLOY_HOME/.ssh/authorized_keys"
  echo "[root] added SSH key for $DEPLOY_USER"
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_HOME/.ssh"
chmod 700 "$DEPLOY_HOME/.ssh"
chmod 600 "$DEPLOY_HOME/.ssh/authorized_keys"

# ── 3. SSH harden ──────────────────────────────────────
sed -i.bak 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh
echo "[root] SSH hardened (no password auth, root key-only)"

# ── 4. apt deps ────────────────────────────────────────
echo "[root] installing system deps (docker, caddy, git, curl, openssl, ufw)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  docker.io \
  docker-compose-plugin \
  git \
  curl \
  openssl \
  ufw \
  ca-certificates \
  >/dev/null

# Caddy needs its own apt repo
if ! command -v caddy >/dev/null 2>&1; then
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https >/dev/null
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
  echo "[root] installed Caddy"
fi

# ── 5. docker group ───────────────────────────────────
usermod -aG docker "$DEPLOY_USER"
echo "[root] added $DEPLOY_USER to docker group"

# ── 6. firewall ───────────────────────────────────────
ufw allow 22/tcp >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
echo "[root] ufw enabled (22/80/443 open)"

# ── done ──────────────────────────────────────────────
HOST_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "================================================================"
echo " ✓ root phase complete"
echo ""
echo " NEXT: from your laptop, ssh in as $DEPLOY_USER and run phase 2:"
echo ""
echo "   ssh $DEPLOY_USER@$HOST_IP"
echo "   curl -fsSL https://raw.githubusercontent.com/Lingo2018/web-hub/master/scripts/bootstrap-vps-deploy.sh -o bootstrap-vps-deploy.sh"
echo "   bash bootstrap-vps-deploy.sh   # generates .bootstrap.env template, fill it in, re-run"
echo "================================================================"
