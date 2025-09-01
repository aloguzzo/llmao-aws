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

# Function to backup OpenWebUI volume only
backup_openwebui() {
    local volume_name="llm-stack_openwebui-data"
    local backup_name="openwebui-data"
    local s3_key="backups/${backup_name}_${TIMESTAMP}.tar.gz"
    local temp_dir
    temp_dir="/tmp/docker_backup_$$_$(date +%s)"
    local archive_file="${temp_dir}.tar.gz"

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
        return 0
    fi

    # Create temporary container to access volume data
    local container_id
    container_id=$(run_as_ubuntu docker create -v "${volume_name}:/source:ro" ubuntu:24.04)

    # Create temp directory for backup
    if [[ "$(whoami)" = "ubuntu" ]]; then
        mkdir -p "$temp_dir"
    else
        sudo -u ubuntu mkdir -p "$temp_dir"
    fi

    # Copy data from volume to temp directory
    log "  Copying data from volume..."
    if run_as_ubuntu docker cp "$container_id:/source/." "$temp_dir/"; then
        # Check what we actually copied
        local copied_files
        copied_files=$(find "$temp_dir" -type f 2>/dev/null | wc -l)
        log "  Copied $copied_files files to temporary directory"

        # List some files for debugging (limit to first 5)
        if [[ "$copied_files" -gt 0 ]]; then
            log "  Sample files:"
            find "$temp_dir" -type f | head -5 | while read -r file; do
                log "    $(basename "$file")"
            done
        fi

        # Create compressed archive to local file first
        log "  Creating compressed archive..."
        if tar -C "$temp_dir" -czf "$archive_file" .; then
            local archive_size
            archive_size=$(stat -c%s "$archive_file" 2>/dev/null || stat -f%z "$archive_file" 2>/dev/null || echo "unknown")
            log "  Archive created: $(numfmt --to=iec --suffix=B "$archive_size" 2>/dev/null || echo "$archive_size bytes")"

            # Upload to S3
            log "  Uploading to S3..."
            if aws s3 cp "$archive_file" "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION"; then
                log "✓ Successfully backed up $volume_name to s3://${BACKUP_BUCKET}/${s3_key}"

                # Get backup size from S3
                local s3_size
                s3_size=$(aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" | awk '{print $3}')
                log "  S3 backup size: $(numfmt --to=iec --suffix=B "$s3_size" 2>/dev/null || echo "$s3_size bytes")"
            else
                log "✗ Failed to upload backup to S3"
                # Cleanup on error
                run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
                rm -rf "$temp_dir" || true
                rm -f "$archive_file" || true
                return 1
            fi
        else
            log "✗ Failed to create archive"
            # Cleanup on error
            run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
            rm -rf "$temp_dir" || true
            return 1
        fi
    else
        log "✗ Failed to copy data from volume $volume_name"
        # Cleanup on error
        run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
        rm -rf "$temp_dir" || true
        return 1
    fi

    # Cleanup on success
    run_as_ubuntu docker rm -f "$container_id" >/dev/null 2>&1 || true
    rm -rf "$temp_dir" || true
    rm -f "$archive_file" || true

    log "✓ OpenWebUI backup completed successfully"
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

# Backup only OpenWebUI volume
backup_openwebui

log "Listing recent backups in S3:"
aws s3 ls "s3://${BACKUP_BUCKET}/backups/" --region "$AWS_REGION" --human-readable --summarize | tail -10

log "Backup process completed"