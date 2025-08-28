#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

cd /opt/app/compose

log "Pulling latest Docker images..."
docker compose pull

log "Recreating containers with new images..."
docker compose up -d

log "Cleaning up old images..."
docker image prune -f

log "Current container status:"
docker compose ps