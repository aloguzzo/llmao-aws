#!/usr/bin/env bash
set -euo pipefail

# Terraform template variables (stubs for ShellCheck only; harmless at runtime)
# shellcheck disable=SC2034
domain_name='' acme_email='' aws_region='' github_repo_url='' use_private=''

# Real variables: values are injected by Terraform templatefile() at render time
DOMAIN_NAME="${domain_name}"
ACME_EMAIL="${acme_email}"
AWS_REGION="${aws_region}"
GITHUB_REPO_URL="${github_repo_url}"
USE_PRIVATE="${use_private}"
readonly DOMAIN_NAME ACME_EMAIL AWS_REGION GITHUB_REPO_URL USE_PRIVATE

log() { echo "[$(date -Is)] $*"; }

log "Updating apt and installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip snapd openssh-client

log "Install AWS CLI v2"
tmpdir=$(mktemp -d)
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "$tmpdir/awscliv2.zip"
unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
"$tmpdir/aws/install" >/dev/null
rm -rf "$tmpdir"

log "Install and enable SSM Agent"
snap install amazon-ssm-agent --classic
systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service

log "Install Docker Engine + Compose plugin"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
ARCH="arm64"
# Quote VERSION_CODENAME to avoid word splitting/globbing
echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Add both ubuntu and ssm-user to docker group
usermod -aG docker ubuntu || true
usermod -aG docker ssm-user || true

log "Prepare app directory with proper ownership"
mkdir -p /opt/app
chown -R ubuntu:ubuntu /opt/app
chmod 755 /opt/app

# If private repo, fetch deploy key from SSM and configure SSH for ubuntu user
if [ "$USE_PRIVATE" = "true" ]; then
  log "Configuring SSH deploy key for GitHub"
  sudo -u ubuntu mkdir -p /home/ubuntu/.ssh
  chmod 700 /home/ubuntu/.ssh

  # Fetch private key (ed25519) from SSM: /app/github/deploy_key_priv
  DEPLOY_KEY="$(aws ssm get-parameter --with-decryption --name "/app/github/deploy_key_priv" --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -z "$DEPLOY_KEY" ]; then
    log "ERROR: SSM parameter /app/github/deploy_key_priv not found or empty."
    exit 1
  fi

  # Write key content securely as ubuntu user (avoid Terraform interpolation collisions)
  sudo -u ubuntu env DEPLOY_KEY="$DEPLOY_KEY" bash -lc 'umask 177; printf "%s\n" "$DEPLOY_KEY" > /home/ubuntu/.ssh/id_ed25519'
  chown ubuntu:ubuntu /home/ubuntu/.ssh/id_ed25519
  chmod 600 /home/ubuntu/.ssh/id_ed25519

  cat >/home/ubuntu/.ssh/config <<'CFG'
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_ed25519
  StrictHostKeyChecking yes
  IdentitiesOnly yes
CFG
  chown ubuntu:ubuntu /home/ubuntu/.ssh/config
  chmod 600 /home/ubuntu/.ssh/config

  # Append GitHub host keys as ubuntu user (fix sudo redirection issue)
  ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null | sudo -u ubuntu tee -a /home/ubuntu/.ssh/known_hosts >/dev/null
  chown ubuntu:ubuntu /home/ubuntu/.ssh/known_hosts
  chmod 644 /home/ubuntu/.ssh/known_hosts
fi

log "Clone or update repository $GITHUB_REPO_URL"
if [ ! -d "/opt/app/.git" ]; then
  sudo -u ubuntu git clone "$GITHUB_REPO_URL" /opt/app
else
  cd /opt/app
  # Ensure both pull and fallback fetch run as ubuntu
  sudo -u ubuntu bash -lc 'git pull --ff-only || git fetch --all --prune'
fi

# Configure git safe directory for ubuntu user
sudo -u ubuntu git config --global --add safe.directory /opt/app

# Compose expects /opt/app/compose/compose.yml and /opt/app/caddy/Caddyfile
if [ ! -f "/opt/app/compose/compose.yml" ]; then
  log "ERROR: compose/compose.yml not found in repo. Exiting."
  exit 1
fi

log "Create compose .env with runtime configuration"
ENV_FILE="/opt/app/compose/.env"
: > "$ENV_FILE"
{
  echo "CADDY_DOMAIN=$DOMAIN_NAME"
  echo "ACME_EMAIL=$ACME_EMAIL"
} >> "$ENV_FILE"

# Fetch OpenAI API key from SSM if present: /app/litellm/openai_api_key
OPENAI_API_KEY="$(aws ssm get-parameter --with-decryption --name "/app/litellm/openai_api_key" --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
if [ -n "$OPENAI_API_KEY" ]; then
  echo "OPENAI_API_KEY=$OPENAI_API_KEY" >> "$ENV_FILE"
fi
chown ubuntu:ubuntu "$ENV_FILE"

log "Docker Compose pull and up (as ubuntu user)"
cd /opt/app/compose
sudo -u ubuntu docker compose --env-file .env pull
sudo -u ubuntu docker compose --env-file .env up -d

log "Bootstrap complete"