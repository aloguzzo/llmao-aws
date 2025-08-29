#!/usr/bin/env bash
set -euo pipefail

BACKUP_BUCKET="${BACKUP_BUCKET:-}"
AWS_REGION="${AWS_REGION:-eu-central-1}"
RESTORE_DATE="${1:-}"

log() { echo "[$(date -Is)] $*"; }

# Function to run commands as ubuntu user
run_as_ubuntu() {
    if [ "$(whoami)" = "ubuntu" ]; then
        "$@"
    else
        sudo -u ubuntu "$@"
    fi
}

usage() {
    echo "Usage: $0 [YYYYMMDD_HHMMSS]"
    echo "If no date specified, will show available backups"
    echo ""
    echo "Examples:"
    echo "  $0                    # List available backups"
    echo "  $0 20241201_143022    # Restore backup from specific timestamp"
}

# Get backup bucket from terraform output if not set
if [[ -z "$BACKUP_BUCKET" ]]; then
    BACKUP_BUCKET="$(terraform -chdir=/opt/app/terraform output -raw backup_bucket 2>/dev/null || echo '')"
    if [[ -z "$BACKUP_BUCKET" ]]; then
        log "ERROR: Could not determine backup bucket. Set BACKUP_BUCKET environment variable."
        exit 1
    fi
fi

# If no date specified, list available backups
if [[ -z "$RESTORE_DATE" ]]; then
    log "Available backups in s3://${BACKUP_BUCKET}/backups/:"
    aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" --human-readable | \
    grep -E "(openwebui-data|caddy-data|caddy-config)" | \
    sort -k4 | \
    tail -20
    echo ""
    usage
    exit 0
fi

cd /opt/app/compose

log "WARNING: This will replace current volume data with backup from $RESTORE_DATE"
read -p "Are you sure? (yes/no): " -r
if [[ ! $REPLY =~ ^yes$ ]]; then
    log "Restore cancelled"
    exit 0
fi

# Stop services first
log "Stopping services..."
run_as_ubuntu docker compose down

# Function to restore a volume from S3
restore_volume() {
    local volume_name="$1"
    local backup_name="$2"
    local s3_key="backups/${backup_name}_${RESTORE_DATE}.tar.gz"

    log "Restoring volume: $volume_name from $s3_key"

    # Check if backup exists
    if ! aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" >/dev/null 2>&1; then
        log "ERROR: Backup not found: s3://${BACKUP_BUCKET}/${s3_key}"
        return 1
    fi

    # Remove existing volume and recreate
    run_as_ubuntu docker volume rm "$volume_name" 2>/dev/null || true
    run_as_ubuntu docker volume create "$volume_name"

    # Stream restore from S3
    if run_as_ubuntu docker run --rm \
        -v "${volume_name}:/target" \
        --env AWS_DEFAULT_REGION="$AWS_REGION" \
        amazon/aws-cli:latest \
        bash -c "
            aws s3 cp s3://${BACKUP_BUCKET}/${s3_key} - | tar -xzf - -C /target
        "; then
        log "✓ Successfully restored $volume_name"
    else
        log "✗ Failed to restore $volume_name"
        return 1
    fi
}

# Restore volumes
restore_volume "compose_openwebui-data" "openwebui-data"
restore_volume "compose_caddy-data" "caddy-data"
restore_volume "compose_caddy-config" "caddy-config"

# Start services
log "Starting services..."
run_as_ubuntu docker compose up -d

log "Restore completed successfully"
log "Container status:"
run_as_ubuntu docker compose ps