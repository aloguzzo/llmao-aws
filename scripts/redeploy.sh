#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

# Function to run commands as ubuntu user (handles both direct ubuntu and ssm-user contexts)
run_as_ubuntu() {
    if [ "$(whoami)" = "ubuntu" ]; then
        "$@"
    else
        sudo -u ubuntu "$@"
    fi
}

log "Starting redeploy process..."

cd /opt/app

log "Fetching latest changes from git repository..."
run_as_ubuntu git fetch --all --prune

log "Pulling latest changes..."
run_as_ubuntu git pull

cd compose

log "Pulling latest Docker images..."
run_as_ubuntu docker compose pull

log "Recreating containers with updated images..."
run_as_ubuntu docker compose up -d

log "Cleaning up unused images..."
run_as_ubuntu docker image prune -f

log "Redeploy completed. Current status:"
run_as_ubuntu docker compose ps