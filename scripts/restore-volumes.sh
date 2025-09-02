#!/usr/bin/env bash
set -euo pipefail

# Restore Docker volumes from S3 with robust error handling.
#
# Defaults:
# - Restores: openwebui-data, caddy-data, caddy-config
# - Stops all services during restore
# - Determines bucket via BACKUP_BUCKET or Terraform output
#
# Environment variables:
#   BACKUP_BUCKET       S3 bucket to restore from (required unless Terraform output available)
#   AWS_REGION          AWS region (default: eu-central-1)
#   TARGETS             Space/comma-separated: openwebui-data caddy-data caddy-config (default: all)
#   COMPOSE_DIR         Path to docker compose project (default: /opt/app/compose)
#   HELPER_IMAGE        Helper container image to run tar/extract (default: ubuntu:24.04)
#   S3_PREFIX           S3 prefix for objects (default: backups)
#
# Usage:
#   $0 [YYYYMMDD_HHMMSS]
#   If no date specified, will show available backups
#
# Exit codes:
#   0 on success
#   non-zero if a restore operation fails

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/app/compose}"
HELPER_IMAGE="${HELPER_IMAGE:-ubuntu:24.04}"
S3_PREFIX="${S3_PREFIX:-backups}"
RESTORE_DATE="${1:-}"

# Default targets (short names as they appear in compose volumes:)
DEFAULT_TARGETS=(openwebui-data caddy-data caddy-config)

# Parse TARGETS env (space or comma separated)
if [[ -n "${TARGETS:-}" ]]; then
  # Replace commas with spaces, then read into array
  TARGETS_PARSED=()
  IFS=' ,'; read -r -a TARGETS_PARSED <<< "${TARGETS}"
  TARGETS=("${TARGETS_PARSED[@]}")
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

log()   { echo "[$(date -Is)] $*"; }
warn()  { echo "[$(date -Is)] WARNING: $*" >&2; }
die()   { echo "[$(date -Is)] ERROR: $*" >&2; exit 1; }

# Run commands as ubuntu user when present, fall back to current user otherwise
run_as_ubuntu() {
  if id -u ubuntu >/dev/null 2>&1; then
    if [[ "$(id -un)" == "ubuntu" ]]; then
      "$@"
    else
      if command -v sudo >/dev/null 2>&1; then
        sudo -n -u ubuntu "$@"
      else
        warn "sudo not available; running command as current user: $*"
        "$@"
      fi
    fi
  else
    "$@"
  fi
}

# Shortcuts for docker and docker compose
d() { run_as_ubuntu docker "$@"; }
dc() { run_as_ubuntu docker compose "$@"; }

# Track temp dirs for cleanup
TEMP_DIRS=()
cleanup() {
  # Remove temp directories
  if [[ "${#TEMP_DIRS[@]}" -gt 0 ]]; then
    for tdir in "${TEMP_DIRS[@]}"; do
      rm -rf "$tdir" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

usage() {
  echo "Usage: $0 [YYYYMMDD_HHMMSS]"
  echo "If no date specified, will show available backups"
  echo ""
  echo "Examples:"
  echo "  $0                    # List available backups"
  echo "  $0 20241201_143022    # Restore backup from specific timestamp"
}

check_prereqs() {
  local missing=()

  for cmd in docker aws tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  # docker compose (plugin) check
  if ! docker compose version >/dev/null 2>&1; then
    missing+=("docker-compose-plugin")
  fi
  # sudo is needed only if not ubuntu user but ubuntu user exists
  if id -u ubuntu >/dev/null 2>&1 && [[ "$(id -un)" != "ubuntu" ]]; then
    command -v sudo >/dev/null 2>&1 || missing+=("sudo")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing prerequisites: ${missing[*]}"
  fi
}

ensure_compose_dir() {
  if [[ ! -d "$COMPOSE_DIR" ]]; then
    die "Compose directory not found: $COMPOSE_DIR"
  fi
  cd "$COMPOSE_DIR"
}

detect_project_name() {
  local from_file
  # Extract "name:" from compose.yml (simple YAML parse)
  if [[ -f "compose.yml" ]]; then
    from_file="$(sed -n -E 's/^[[:space:]]*name:[[:space:]]*([A-Za-z0-9_.-]+).*/\1/p' compose.yml | head -n1 || true)"
  fi
  if [[ -n "${from_file:-}" ]]; then
    PROJECT_NAME="$from_file"
  else
    # Fallback: directory name
    PROJECT_NAME="$(basename "$COMPOSE_DIR")"
  fi
  log "Detected Compose project name: $PROJECT_NAME"
}

resolve_backup_bucket() {
  if [[ -n "${BACKUP_BUCKET:-}" ]]; then
    return 0
  fi

  # Terraform discovery (optional)
  if command -v terraform >/dev/null 2>&1 && [[ -d "/opt/app/terraform" ]]; then
    BACKUP_BUCKET="$(terraform -chdir=/opt/app/terraform output -raw backup_bucket 2>/dev/null || true)"
    if [[ -n "$BACKUP_BUCKET" ]]; then
      log "Discovered backup bucket via Terraform: $BACKUP_BUCKET"
      return 0
    fi
    warn "Terraform present but could not read output 'backup_bucket' (is state initialized?)."
  fi

  die "No BACKUP_BUCKET provided and Terraform discovery failed. Set BACKUP_BUCKET env var."
}

ensure_helper_image() {
  if ! d image inspect "$HELPER_IMAGE" >/dev/null 2>&1; then
    log "Pulling helper image: $HELPER_IMAGE"
    d pull "$HELPER_IMAGE"
  fi
}

human_bytes() {
  local bytes="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes} bytes"
  else
    echo "${bytes} bytes"
  fi
}

list_available_backups() {
  log "Available backups in s3://${BACKUP_BUCKET}/${S3_PREFIX}/"
  if aws s3 ls "s3://${BACKUP_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" --human-readable --summarize >/tmp/s3_list.$$ 2>/dev/null; then
    # Filter for target volumes and show recent ones
    grep -E "($(IFS='|'; echo "${TARGETS[*]}"))" /tmp/s3_list.$$ | sort -k4 | tail -20 || true
    rm -f /tmp/s3_list.$$ || true
  else
    warn "Could not list backups (insufficient permissions or bucket/region mismatch)"
  fi
}

restore_volume() {
  local short_name="$1"              # e.g., openwebui-data
  local volume_name="${PROJECT_NAME}_${short_name}"
  local archive_name="${short_name}_${RESTORE_DATE}.tar.gz"
  local s3_key="${S3_PREFIX}/${archive_name}"

  log "Restoring volume: $volume_name"

  # Check if backup exists
  if ! aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" >/dev/null 2>&1; then
    warn "Backup not found, skipping: s3://${BACKUP_BUCKET}/${s3_key}"
    return 0
  fi

  # Get backup info
  local backup_info s3_len=""
  backup_info="$(aws s3 ls "s3://${BACKUP_BUCKET}/${s3_key}" --region "$AWS_REGION" --human-readable || true)"
  s3_len="$(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$s3_key" --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo "")"

  if [[ -n "$s3_len" && "$s3_len" != "None" ]]; then
    log "Backup size: $(human_bytes "$s3_len")"
  elif [[ -n "$backup_info" ]]; then
    log "Backup size: $(echo "$backup_info" | awk '{print $3 " " $4}')"
  fi

  # Prepare temp dir to receive extracted files
  local tdir
  tdir="$(mktemp -d "/tmp/${volume_name//\//_}.XXXXXX")"
  TEMP_DIRS+=("$tdir")

  # Download and extract backup using helper container
  log "Downloading and extracting backup from S3..."
  # Build inner command for helper container
  local inner_cmd
  inner_cmd=$(
    cat <<EOF
set -euo pipefail
aws s3 cp "s3://${BACKUP_BUCKET}/${s3_key}" - --region "${AWS_REGION}" | tar -xzf - -C /restore
EOF
  )

  if d run --rm \
    -v "${tdir}:/restore" \
    -e "AWS_DEFAULT_REGION=${AWS_REGION}" \
    -e "AWS_REGION=${AWS_REGION}" \
    "$HELPER_IMAGE" bash -lc "$inner_cmd"; then
    log "Successfully downloaded and extracted backup"
  else
    die "Failed to download backup from s3://${BACKUP_BUCKET}/${s3_key}"
  fi

  # Count files in backup
  local file_count
  file_count="$(find "$tdir" -type f 2>/dev/null | wc -l)"
  log "Backup contains $file_count files"

  # List some files for verification
  if [[ "$file_count" -gt 0 ]]; then
    log "Sample files in backup:"
    find "$tdir" -type f | head -5 | while read -r file; do
      log "  $(basename "$file")"
    done
  fi

  # Remove existing volume and recreate
  log "Removing existing volume..."
  d volume rm "$volume_name" 2>/dev/null || true
  d volume create "$volume_name"

  # Restore data using helper container
  log "Copying data to volume..."
  if [[ "$file_count" -gt 0 ]]; then
    # Build inner command for data copy
    local copy_cmd
    copy_cmd=$(
      cat <<EOF
set -euo pipefail
shopt -s dotglob nullglob
if [ -n "\$(ls -A /source 2>/dev/null)" ]; then
  cp -a /source/. /target/
else
  echo "Source directory is empty"
fi
EOF
    )

    if d run --rm \
      -v "${tdir}:/source:ro" \
      -v "${volume_name}:/target" \
      "$HELPER_IMAGE" bash -lc "$copy_cmd"; then
      log "Successfully restored $volume_name"
    else
      die "Failed to copy data to volume $volume_name"
    fi
  else
    log "Volume was empty, restored empty volume"
  fi

  # Remove temp dir for this volume immediately (also covered by trap)
  rm -rf "$tdir" >/dev/null 2>&1 || true
}

main() {
  log "Starting restore process"
  check_prereqs
  ensure_compose_dir
  detect_project_name
  resolve_backup_bucket
  ensure_helper_image

  # If no date specified, list available backups and exit
  if [[ -z "$RESTORE_DATE" ]]; then
    list_available_backups
    echo ""
    usage
    exit 0
  fi

  log "WARNING: This will replace current volume data with backup from $RESTORE_DATE"
  read -p "Are you sure? (yes/no): " -r
  if [[ ! $REPLY =~ ^yes$ ]]; then
    log "Restore cancelled"
    exit 0
  fi

  log "Current Docker volumes before restore:"
  d volume ls | grep "$PROJECT_NAME" || true

  # Stop services first
  log "Stopping services..."
  dc down

  log "Compose project status (post-stop):"
  dc ps || true

  local failures=0
  for tgt in "${TARGETS[@]}"; do
    if ! restore_volume "$tgt"; then
      warn "Restore failed for: $tgt"
      failures=$((failures + 1))
    fi
  done

  if [[ $failures -gt 0 ]]; then
    die "Restore completed with $failures failure(s)"
  fi

  # Start services
  log "Starting services..."
  dc up -d

  # Wait a moment for services to start
  sleep 5

  log "Container status:"
  dc ps

  log "Restored Docker volumes:"
  d volume ls | grep "$PROJECT_NAME" || true

  log "Restore process completed successfully"
}

main "$@"
