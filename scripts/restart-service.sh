#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:-}"
if [ -z "$SERVICE_NAME" ]; then
    echo "Usage: $0 <service_name>"
    echo "Available services: caddy, openwebui, litellm"
    exit 1
fi

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

log "Restarting service: $SERVICE_NAME"
run_as_ubuntu docker compose restart "$SERVICE_NAME"

log "Service status:"
run_as_ubuntu docker compose ps "$SERVICE_NAME"

log "Recent logs:"
run_as_ubuntu docker compose logs --tail=30 "$SERVICE_NAME"