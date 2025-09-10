#!/usr/bin/env zsh
set -euo pipefail

REGION="eu-central-1"
INSTANCE_ID=""

# Check for session-manager-plugin
check_session_manager() {
    if ! command -v session-manager-plugin &> /dev/null; then
        echo "Error: session-manager-plugin is not installed or not in PATH"
        echo ""
        echo "To install on macOS:"
        echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-macos-overview.html"
        return 1
    fi
}

# Get instance ID
get_instance_id() {
    if [[ -z "$INSTANCE_ID" ]]; then
        INSTANCE_ID="$(terraform -chdir=terraform output -raw instance_id 2>/dev/null || echo '')"
        if [[ -z "$INSTANCE_ID" ]]; then
            echo "Error: Could not get instance ID. Run terraform apply first."
            exit 1
        fi
    fi
}

usage() {
    cat <<EOF
Usage: $0 <command> [options]

Application Management:
  status              - Show application status
  update              - Update Docker images
  restart             - Restart entire stack
  restart-caddy       - Restart only Caddy
  restart-openwebui   - Restart only OpenWebUI
  restart-litellm     - Restart only LiteLLM
  backup              - Backup Docker volumes
  redeploy            - Pull git changes and redeploy
  list-backups        - List available backups on S3
  logs-caddy [lines]  - Show Caddy logs (default: 50 lines)
  logs-openwebui [lines] - Show OpenWebUI logs
  logs-litellm [lines]   - Show LiteLLM logs

Instance Management:
  stop                - Stop EC2 instance
  start               - Start EC2 instance
  instance-status     - Show instance status

Interactive:
  shell               - Start SSM shell session

Examples:
  $0 status
  $0 restart-openwebui
  $0 logs-caddy 100
  $0 stop
EOF
}

invoke_app_command() {
    local script_command="$1"

    check_session_manager || exit 1

    echo "Executing: $script_command"
    echo "Starting interactive session..."

    aws ssm start-session --target "$INSTANCE_ID" --region "$REGION" --document-name "AWS-StartInteractiveCommand" --parameters "command=\"$script_command\""
}

get_instance_id

case "${1:-}" in
    status)
        invoke_app_command "cd /opt/app && bash scripts/status.sh"
        ;;
    update)
        invoke_app_command "cd /opt/app && bash scripts/update-images.sh"
        ;;
    restart)
        invoke_app_command "cd /opt/app && bash scripts/restart-stack.sh"
        ;;
    restart-caddy)
        invoke_app_command "cd /opt/app && bash scripts/restart-service.sh caddy"
        ;;
    restart-openwebui)
        invoke_app_command "cd /opt/app && bash scripts/restart-service.sh openwebui"
        ;;
    restart-litellm)
        invoke_app_command "cd /opt/app && bash scripts/restart-service.sh litellm"
        ;;
    backup)
        # Set backup bucket environment variable
        backup_bucket="$(terraform -chdir=terraform output -raw backup_bucket 2>/dev/null || echo '')"
        if [[ -n "$backup_bucket" ]]; then
            invoke_app_command "cd /opt/app && BACKUP_BUCKET=$backup_bucket bash scripts/backup-volumes.sh"
        else
            invoke_app_command "cd /opt/app && bash scripts/backup-volumes.sh"
        fi
        ;;
    list-backups)
        # Set backup bucket environment variable
        backup_bucket="$(terraform -chdir=terraform output -raw backup_bucket 2>/dev/null || echo '')"
        if [[ -n "$backup_bucket" ]]; then
            invoke_app_command "cd /opt/app && BACKUP_BUCKET=$backup_bucket bash scripts/restore-volumes.sh"
        else
            invoke_app_command "cd /opt/app && bash scripts/restore-volumes.sh"
        fi
        ;;
    redeploy)
        invoke_app_command "cd /opt/app && bash scripts/redeploy.sh"
        ;;

    logs-caddy)
        invoke_app_command "cd /opt/app/compose && docker compose logs --tail=${2:-50} caddy"
        ;;
    logs-openwebui)
        invoke_app_command "cd /opt/app/compose && docker compose logs --tail=${2:-50} openwebui"
        ;;
    logs-litellm)
        invoke_app_command "cd /opt/app/compose && docker compose logs --tail=${2:-50} litellm"
        ;;
    stop)
        echo "Stopping instance..."
        aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    start)
        echo "Starting instance..."
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
        ;;
    instance-status)
        aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query 'Reservations[0].Instances[0].State.Name' --output text
        ;;
    shell)
        check_session_manager || exit 1
        aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
        ;;
    *)
        usage
        exit 1
        ;;
esac