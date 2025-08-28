#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

log "Starting redeploy process..."

cd /opt/app

log "Updating git repository..."
git pull --ff-only || {
    log "Fast-forward failed, fetching all branches..."
    git fetch --all --prune
}

cd compose

log "Pulling latest Docker images..."
docker compose pull

log "Recreating containers with updated images..."
docker compose up -d

log "Cleaning up unused images..."
docker image prune -f

log "Redeploy completed. Current status:"
docker compose ps