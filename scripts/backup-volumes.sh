#!/usr/bin/env bash
set -euo pipefail

# Backup Docker volumes to S3 with service quiescing and robust error handling.
#
# Defaults:
# - Backs up: openwebui-data, caddy-data, caddy-config
# - Quiesces services with docker compose pause/unpause
# - Determines bucket via BACKUP_BUCKET or Terraform output
#
# Environment variables:
#   BACKUP_BUCKET       S3 bucket to upload to (required unless Terraform output available)
#   AWS_REGION          AWS region (default: eu-central-1)
#   TARGETS             Space/comma-separated: openwebui-data caddy-data caddy-config (default: all)
#   QUIESCE_MODE        pause | stop | none (default: pause)
#   COMPOSE_DIR         Path to docker compose project (default: /opt/app/compose)
#   HELPER_IMAGE        Helper container image to run tar/find (default: ubuntu:24.04)
#   S3_PREFIX           S3 prefix for objects (default: backups)
#   FORCE_SSE_AES256    If "true", add --sse AES256 on upload
#   S3_KMS_KEY_ID       If set, use KMS: --sse aws:kms --sse-kms-key-id
#
# Exit codes:
#   0 on success (even if some volumes are empty)
#   non-zero if a backup operation fails unexpectedly

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-central-1}}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/app/compose}"
HELPER_IMAGE="${HELPER_IMAGE:-ubuntu:24.04}"
S3_PREFIX="${S3_PREFIX:-backups}"
QUIESCE_MODE="${QUIESCE_MODE:-pause}"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"

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

# Track quiesced services and temp dirs for cleanup
PAUSED_SERVICES=()
STOPPED_SERVICES=()
TEMP_DIRS=()
cleanup() {
  # Unpause or start services as needed
  if [[ "${#PAUSED_SERVICES[@]}" -gt 0 ]]; then
    for svc in "${PAUSED_SERVICES[@]}"; do
      dc unpause "$svc" >/dev/null 2>&1 || true
    done
  fi
  if [[ "${#STOPPED_SERVICES[@]}" -gt 0 ]]; then
    for svc in "${STOPPED_SERVICES[@]}"; do
      dc start "$svc" >/dev/null 2>&1 || true
    done
  fi
  # Remove temp directories
  if [[ "${#TEMP_DIRS[@]}" -gt 0 ]]; then
    for tdir in "${TEMP_DIRS[@]}"; do
      rm -rf "$tdir" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

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

quiesce_services() {
  # We quiesce services that write to the volumes we back up.
  # - openwebui -> openwebui-data
  # - caddy     -> caddy-data, caddy-config
  local services=()
  # include only relevant services based on targets
  local need_openwebui=false need_caddy=false
  for tgt in "${TARGETS[@]}"; do
    case "$tgt" in
      openwebui-data) need_openwebui=true ;;
      caddy-data|caddy-config) need_caddy=true ;;
    esac
  done
  $need_openwebui && services+=("openwebui")
  $need_caddy && services+=("caddy")
  if [[ "${#services[@]}" -eq 0 || "$QUIESCE_MODE" == "none" ]]; then
    log "Skipping quiesce (mode=$QUIESCE_MODE; services derived: none)"
    return 0
  fi

  case "$QUIESCE_MODE" in
    pause)
      log "Pausing services: ${services[*]}"
      for svc in "${services[@]}"; do
        dc pause "$svc" >/dev/null 2>&1 || true
        PAUSED_SERVICES+=("$svc")
      done
      ;;
    stop)
      log "Stopping services: ${services[*]}"
      for svc in "${services[@]}"; do
        dc stop "$svc" >/dev/null 2>&1 || true
        STOPPED_SERVICES+=("$svc")
      done
      ;;
    *)
      warn "Unknown QUIESCE_MODE=$QUIESCE_MODE; skipping quiesce"
      ;;
  esac
}

backup_volume() {
  local short_name="$1"              # e.g., openwebui-data
  local volume_name="${PROJECT_NAME}_${short_name}"
  local archive_name="${short_name}_${TIMESTAMP}.tar.gz"
  local s3_key="${S3_PREFIX}/${archive_name}"

  log "Backing up volume: $volume_name"

  # Check volume existence
  if ! d volume inspect "$volume_name" >/dev/null 2>&1; then
    warn "Volume not found, skipping: $volume_name"
    return 0
  fi

  # Probe contents (guarded against failure)
  local file_count size_str
  file_count="$(d run --rm -v "${volume_name}:/source:ro" "$HELPER_IMAGE" bash -lc 'shopt -s dotglob nullglob; find /source -type f | wc -l' 2>/dev/null || echo "unknown")"
  size_str="$(d run --rm -v "${volume_name}:/source:ro" "$HELPER_IMAGE" bash -lc 'du -sh /source 2>/dev/null | cut -f1' 2>/dev/null || echo "unknown")"
  log "Volume content: files=${file_count}, size=${size_str}"

  # Prepare temp dir to receive archive
  local tdir
  tdir="$(mktemp -d "/tmp/${volume_name//\//_}.XXXXXX")"
  TEMP_DIRS+=("$tdir")
  local archive_path="${tdir}/${archive_name}"

  # Create archive inside helper container
  log "Creating archive: ${archive_path}"
  # Build inner command carefully with quoting
  local inner_cmd
  inner_cmd=$(
    cat <<EOF
set -euo pipefail
shopt -s dotglob nullglob
if [ -z "\$(ls -A /source 2>/dev/null)" ]; then
  # empty volume -> create empty tar
  tar -czf "/backup/${archive_name}" -T /dev/null
else
  tar -C /source -czf "/backup/${archive_name}" .
fi
EOF
  )
  d run --rm \
    -v "${volume_name}:/source:ro" \
    -v "${tdir}:/backup" \
    "$HELPER_IMAGE" bash -lc "$inner_cmd"

  # Local archive stats
  local bytes=""; bytes="$(stat -c%s "$archive_path" 2>/dev/null || stat -f%z "$archive_path" 2>/dev/null || echo "")"
  if [[ -n "$bytes" ]]; then
    log "Archive created, size=$(human_bytes "$bytes")"
  else
    log "Archive created"
  fi

  # Build S3 SSE args if requested
  local -a s3_args=(--region "$AWS_REGION")
  if [[ -n "${S3_KMS_KEY_ID:-}" ]]; then
    s3_args+=(--sse aws:kms --sse-kms-key-id "$S3_KMS_KEY_ID")
  elif [[ "${FORCE_SSE_AES256:-false}" == "true" ]]; then
    s3_args+=(--sse AES256)
  fi

  # Upload to S3
  log "Uploading to s3://${BACKUP_BUCKET}/${s3_key}"
  if aws s3 cp "$archive_path" "s3://${BACKUP_BUCKET}/${s3_key}" "${s3_args[@]}"; then
    # Verify with head-object (reliable size)
    local s3_len=""
    s3_len="$(aws s3api head-object --bucket "$BACKUP_BUCKET" --key "$s3_key" --region "$AWS_REGION" --query 'ContentLength' --output text 2>/dev/null || echo "")"
    if [[ -n "$s3_len" && "$s3_len" != "None" ]]; then
      log "Uploaded OK, remote size=$(human_bytes "$s3_len")"
    else
      log "Uploaded OK (size check unavailable)"
    fi
  else
    die "Failed to upload ${archive_name} to s3://${BACKUP_BUCKET}/${s3_key}"
  fi

  # Remove temp dir for this volume immediately (also covered by trap)
  rm -rf "$tdir" >/dev/null 2>&1 || true
}

list_recent_backups() {
  log "Recent backups in s3://${BACKUP_BUCKET}/${S3_PREFIX}/"
  if aws s3 ls "s3://${BACKUP_BUCKET}/${S3_PREFIX}/" --region "$AWS_REGION" --human-readable --summarize >/tmp/s3_list.$$ 2>/dev/null; then
    tail -n 20 /tmp/s3_list.$$ || true
    rm -f /tmp/s3_list.$$ || true
  else
    warn "Could not list backups (insufficient permissions or bucket/region mismatch)"
  fi
}

main() {
  log "Starting backup"
  check_prereqs
  ensure_compose_dir
  detect_project_name
  resolve_backup_bucket
  ensure_helper_image

  log "Compose project status (pre-backup):"
  dc ps || true

  quiesce_services

  local failures=0
  for tgt in "${TARGETS[@]}"; do
    if ! backup_volume "$tgt"; then
      warn "Backup failed for: $tgt"
      failures=$((failures + 1))
    fi
  done

  # Resume services before any non-critical post-steps
  # (cleanup trap also ensures resume if we exit here)
  if [[ "${#PAUSED_SERVICES[@]}" -gt 0 ]]; then
    log "Unpausing services: ${PAUSED_SERVICES[*]}"
    for svc in "${PAUSED_SERVICES[@]}"; do
      dc unpause "$svc" >/dev/null 2>&1 || true
    done
    PAUSED_SERVICES=()
  fi
  if [[ "${#STOPPED_SERVICES[@]}" -gt 0 ]]; then
    log "Starting services: ${STOPPED_SERVICES[*]}"
    for svc in "${STOPPED_SERVICES[@]}"; do
      dc start "$svc" >/dev/null 2>&1 || true
    done
    STOPPED_SERVICES=()
  fi

  list_recent_backups

  if [[ $failures -gt 0 ]]; then
    die "Backup completed with $failures failure(s)"
  fi

  log "Backup process completed successfully"
}

main "$@"