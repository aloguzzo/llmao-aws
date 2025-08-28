#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-}"
if [ -z "$SERVICE_NAME" ]; then
    echo "Usage: $0 <service_name>"
    echo "Available services: caddy, openwebui, litellm"
    exit 1
fi

log() { echo "[$(date -Is)] $*"; }

cd /opt/app/compose

log "Restarting service: $SERVICE_NAME"
docker compose restart "$SERVICE_NAME"

log "Service status:"
docker compose ps "$SERVICE_NAME"

log "Recent logs:"
docker compose logs --tail=30 "$SERVICE_NAME"