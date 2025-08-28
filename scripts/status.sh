#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -Is)] $*"; }

cd /opt/app/compose

log "=== Docker Compose Status ==="
docker compose ps

log "=== Docker System Info ==="
docker system df

log "=== Recent Container Logs ==="
echo "--- Caddy ---"
docker compose logs --tail=10 caddy
echo "--- OpenWebUI ---"
docker compose logs --tail=10 openwebui
echo "--- LiteLLM ---"
docker compose logs --tail=10 litellm

log "=== System Resources ==="
df -h /
free -h