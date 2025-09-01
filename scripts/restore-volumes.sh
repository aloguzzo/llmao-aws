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
    local temp_dir
    temp_dir="/tmp/docker_restore_$$_$(date +%s)"

    log "Restoring volume: $volume_name from $s3_key"

    # Check if backup exists
    if ! aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" >/dev/null 2>&1; then
        log "ERROR: Backup not found: s3://${BACKUP_BUCKET}/${s3_key}"
        return 1
    fi

    # Get backup info
    local backup_info
    backup_info=$(aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" --human-readable)
    log "  Backup size: $(echo "$backup_info" | awk '{print $3 " " $4}')"

    # Create temp directory for restore
    mkdir -p "$temp_dir"

    # Ensure cleanup on exit
    trap 'rm -rf "$temp_dir"' EXIT

    # Download and extract backup
    log "  Downloading backup from S3..."
    if aws s3 cp "s3://${BACKUP_BUCKET}/${s3_key}" - --region "$AWS_REGION" | tar -xzf - -C "$temp_dir"; then
        log "  ✓ Downloaded and extracted backup"

        # Count files in backup
        local file_count
        file_count=$(find "$temp_dir" -type f 2>/dev/null | wc -l)
        log "  Backup contains $file_count files"

        # List some files for verification
        if [[ "$file_count" -gt 0 ]]; then
            log "  Sample files in backup:"
            find "$temp_dir" -type f | head -5 | while read -r file; do
                log "    $(basename "$file")"
            done
        fi
    else
        log "  ✗ Failed to download backup"
        return 1
    fi

    # Remove existing volume and recreate
    log "  Removing existing volume..."
    run_as_ubuntu docker volume rm "$volume_name" 2>/dev/null || true
    run_as_ubuntu docker volume create "$volume_name"

    # Create temporary container to restore data
    local container_id
    container_id=$(run_as_ubuntu docker create -v "${volume_name}:/target" ubuntu:24.04)

    # Ensure container cleanup
    trap 'run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true; rm -rf "$temp_dir"' EXIT

    # Copy data from temp directory to volume
    log "  Copying data to volume..."
    if [[ "$file_count" -gt 0 ]]; then
        if run_as_ubuntu docker cp "$temp_dir/." "$container_id:/target/"; then
            log "  ✓ Successfully restored $volume_name"
        else
            log "  ✗ Failed to copy data to volume $volume_name"
            return 1
        fi
    else
        log "  ✓ Volume was empty, restored empty volume"
    fi

    # Cleanup
    run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
    trap - EXIT
}

# Check required tools are available
for cmd in docker aws tar; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

log "Current Docker volumes before restore:"
run_as_ubuntu docker volume ls | grep llm-stack || true

# Restore volumes with CORRECT names
restore_volume "llm-stack_openwebui-data" "openwebui-data"
restore_volume "llm-stack_caddy-data" "caddy-data"
restore_volume "llm-stack_caddy-config" "caddy-config"

# Start services
log "Starting services..."
run_as_ubuntu docker compose up -d

# Wait a moment for services to start
sleep 5

log "Restore completed successfully"
log "Container status:"
run_as_ubuntu docker compose ps

log "Restored Docker volumes:"
run_as_ubuntu docker volume ls | grep llm-stack || true