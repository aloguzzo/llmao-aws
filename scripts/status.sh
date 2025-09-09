#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

# Function to run commands as ubuntu user
run_as_ubuntu() {
    if [ "$(whoami)" = "ubuntu" ]; then
        "$@"
    else
        sudo -u ubuntu "$@"
    fi
}

cd /opt/app/compose

log "=== Docker Compose Status ==="
run_as_ubuntu docker compose ps

log "=== Docker System Info ==="
run_as_ubuntu docker system df

log "=== Recent Container Logs ==="
echo "--- Caddy ---"
run_as_ubuntu docker compose logs --tail=10 caddy
echo "--- OpenWebUI ---"
run_as_ubuntu docker compose logs --tail=10 openwebui
echo "--- LiteLLM ---"
run_as_ubuntu docker compose logs --tail=10 litellm

log "=== System Resources ==="
df -h /
free -h