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

# Function to create and upload backup efficiently
backup_volume() {
    local volume_name="$1"
    local backup_name="$2"
    local s3_key="backups/${backup_name}_${TIMESTAMP}.tar.gz"
    local temp_dir
    temp_dir="/tmp/docker_backup_$$_$(date +%s)"

    log "Backing up volume: $volume_name"

    # First, check if volume exists and has content
    log "Inspecting volume $volume_name..."
    if ! run_as_ubuntu docker volume inspect "$volume_name" >/dev/null 2>&1; then
        log "✗ Volume $volume_name does not exist"
        return 1
    fi

    # Check volume contents
    local file_count
    file_count=$(run_as_ubuntu docker run --rm -v "${volume_name}:/source:ro" ubuntu:24.04 find /source -type f 2>/dev/null | wc -l)
    local dir_size
    dir_size=$(run_as_ubuntu docker run --rm -v "${volume_name}:/source:ro" ubuntu:24.04 du -sh /source 2>/dev/null | cut -f1)

    log "  Volume contains $file_count files, total size: $dir_size"

    if [[ "$file_count" -eq 0 ]]; then
        log "  ⚠ Warning: Volume appears to be empty"
    fi

    # Create temporary container to access volume data
    local container_id
    container_id=$(run_as_ubuntu docker create -v "${volume_name}:/source:ro" ubuntu:24.04)

    # Ensure cleanup on exit - use single quotes to prevent early expansion
    trap 'run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true; rm -rf "$temp_dir"' EXIT

    # Create temp directory for backup
    mkdir -p "$temp_dir"

    # Copy data from volume to temp directory and compress
    log "  Copying data from volume..."
    if run_as_ubuntu docker cp "$container_id:/source/." "$temp_dir/"; then
        # Check what we actually copied
        local copied_files
        copied_files=$(find "$temp_dir" -type f 2>/dev/null | wc -l)
        log "  Copied $copied_files files to temporary directory"

        # List some files for debugging (limit to first 10)
        if [[ "$copied_files" -gt 0 ]]; then
            log "  Sample files:"
            find "$temp_dir" -type f | head -10 | while read -r file; do
                log "    $(basename "$file")"
            done
        fi

        # Create compressed archive and upload to S3
        log "  Creating compressed archive and uploading to S3..."
        if tar -C "$temp_dir" -czf - . | aws s3 cp - "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
            log "✓ Successfully backed up $volume_name to s3://${BACKUP_BUCKET}/${s3_key}"

            # Get backup size
            local size
            size=$(aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" | awk '{print $3}')
            log "  Backup size: $(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "$size bytes")"
        else
            log "✗ Failed to upload backup for $volume_name"
            return 1
        fi
    else
        log "✗ Failed to copy data from volume $volume_name"
        return 1
    fi

    # Cleanup
    run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
    rm -rf "$temp_dir"
    trap - EXIT
}

# Check required tools are available
for cmd in docker aws tar numfmt; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $cmd"
        exit 1
    fi
done

# List all Docker volumes for debugging
log "Available Docker volumes:"
run_as_ubuntu docker volume ls

log "Docker Compose project status:"
run_as_ubuntu docker compose ps

# Backup all volumes with CORRECT names
backup_volume "llm-stack_openwebui-data" "openwebui-data"
backup_volume "llm-stack_caddy-data" "caddy-data"
backup_volume "llm-stack_caddy-config" "caddy-config"

log "Listing recent backups in S3:"
aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" --human-readable --summarize | tail -20

log "Backup completed successfully"

# Clean up old backups (keep last 30 days)
log "Cleaning up backups older than 30 days..."
cutoff_date=$(date -d '30 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-30d '+%Y-%m-%d' 2>/dev/null || echo '')
if [[ -n "$cutoff_date" ]]; then
    aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" | \
    awk -v cutoff="$cutoff_date" '$1" "$2 < cutoff" 00:00:00" {print $4}' | \
    while read -r file; do
        if [[ -n "$file" ]]; then
            log "Deleting old backup: $file"
            aws s3 rm "s3://${BACKUP_BUCKET}/backups/$file" --region "$AWS_REGION" || true
        fi
    done
fi