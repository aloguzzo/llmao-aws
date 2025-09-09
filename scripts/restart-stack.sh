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

log "Stopping all services..."
run_as_ubuntu docker compose down

log "Starting all services..."
run_as_ubuntu docker compose up -d

log "Container status:"
run_as_ubuntu docker compose ps

log "Recent logs from each service:"
run_as_ubuntu docker compose logs --tail=20 caddy
run_as_ubuntu docker compose logs --tail=20 openwebui
run_as_ubuntu docker compose logs --tail=20 litellm