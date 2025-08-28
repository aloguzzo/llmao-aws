#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

cd /opt/app/compose

log "Stopping all services..."
docker compose down

log "Starting all services..."
docker compose up -d

log "Container status:"
docker compose ps

log "Recent logs from each service:"
docker compose logs --tail=20 caddy
docker compose logs --tail=20 openwebui
docker compose logs --tail=20 litellm