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

log "Pulling latest Docker images..."
run_as_ubuntu docker compose pull

log "Recreating containers with new images..."
run_as_ubuntu docker compose up -d

log "Cleaning up old images..."
run_as_ubuntu docker image prune -f

log "Current container status:"
run_as_ubuntu docker compose ps