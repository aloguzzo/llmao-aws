#!/usr/bin/env bash
set -euo pipefail

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_BUCKET="${BACKUP_BUCKET:-}"
AWS_REGION="${AWS_REGION:-eu-central-1}"

log() { echo "[$(date -Is)] $*"; }

# Function to run commands as ubuntu user
run_as_ubuntu() {
    if [ "$(whoami)" = "ubuntu" ]; then
        "$@"
    else
        sudo -u ubuntu "$@"
    fi
}

# Get backup bucket from terraform output if not set
if [[ -z "$BACKUP_BUCKET" ]]; then
    BACKUP_BUCKET="$(terraform -chdir=/opt/app/terraform output -raw backup_bucket 2>/dev/null || echo '')"
    if [[ -z "$BACKUP_BUCKET" ]]; then
        log "ERROR: Could not determine backup bucket. Set BACKUP_BUCKET environment variable."
        exit 1
    fi
fi

cd /opt/app/compose

log "Starting backup to S3 bucket: $BACKUP_BUCKET"

# Function to create and upload backup with resource-efficient streaming
backup_volume() {
    local volume_name="$1"
    local backup_name="$2"
    local s3_key="backups/${backup_name}_${TIMESTAMP}.tar.gz"

    log "Backing up volume: $volume_name"

    # Stream directly to S3 to avoid local disk usage
    if run_as_ubuntu docker run --rm \
        -v "${volume_name}:/source:ro" \
        --env AWS_DEFAULT_REGION="$AWS_REGION" \
        amazon/aws-cli:latest \
        bash -c "
            # Use pigz if available for better compression, fallback to gzip
            if command -v pigz >/dev/null 2>&1; then
                tar -C /source -cf - . | pigz -p 1 | aws s3 cp - s3://${BACKUP_BUCKET}/${s3_key}
            else
                tar -C /source -czf - . | aws s3 cp - s3://${BACKUP_BUCKET}/${s3_key}
            fi
        "; then
        log "✓ Successfully backed up $volume_name to s3://${BACKUP_BUCKET}/${s3_key}"

        # Get backup size
        local size
        size=$(aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" | awk '{print $3}')
        log "  Backup size: $(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size bytes")"
    else
        log "✗ Failed to backup $volume_name"
        return 1
    fi
}

# Backup OpenWebUI data
backup_volume "compose_openwebui-data" "openwebui-data"

# Backup Caddy data (certificates, etc.)
backup_volume "compose_caddy-data" "caddy-data"

# Backup Caddy config
backup_volume "compose_caddy-config" "caddy-config"

log "Listing recent backups in S3:"
aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" --human-readable --summarize | tail -20

log "Backup completed successfully"

# Optional: Clean up old backups (keep last 30 days locally in S3, lifecycle handles long-term)
log "Cleaning up backups older than 30 days..."
cutoff_date=$(date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-30d '+%Y-%m-%d' 2>/dev/null || echo '')
if [[ -n "$cutoff_date" ]]; then
    aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" | \
    awk -v cutoff="$cutoff_date" '$1" "$2 < cutoff" 00:00:00" {print $4}' | \
    while read -r file; do
        if [[ -n "$file" ]]; then
            log "Deleting old backup: $file"
            aws s3 rm "s3://${BACKUP_BUCKET}/backups/$file" --region "$AWS_REGION"
        fi
    done
fi