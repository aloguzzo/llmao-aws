#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/opt/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

log() { echo "[$(date -Is)] $*"; }

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

cd /opt/app/compose

log "Creating backup of Docker volumes..."

# Backup OpenWebUI data
log "Backing up OpenWebUI data..."
docker run --rm \
  -v "compose_openwebui-data:/source:ro" \
  -v "$BACKUP_DIR:/backup" \
  ubuntu:24.04 \
  tar czf "/backup/openwebui-data_${TIMESTAMP}.tar.gz" -C /source .

# Backup Caddy data (certificates, etc.)
log "Backing up Caddy data..."
docker run --rm \
  -v "compose_caddy-data:/source:ro" \
  -v "$BACKUP_DIR:/backup" \
  ubuntu:24.04 \
  tar czf "/backup/caddy-data_${TIMESTAMP}.tar.gz" -C /source .

log "Backup completed. Files created:"
ls -la "$BACKUP_DIR"/*"$TIMESTAMP"*

# Keep only last 7 days of backups
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete