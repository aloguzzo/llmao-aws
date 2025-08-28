#!/usr/bin/env bash
set -euo pipefail

REGION="eu-central-1"
INSTANCE_ID="$(terraform -chdir=terraform output -raw instance_id 2>/dev/null || echo '')"

if [ -z "$INSTANCE_ID" ]; then
    echo "Error: Could not get instance ID. Run terraform apply first."
    exit 1
fi

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

send_app_command() {
    local action="$1"
    local lines="${2:-50}"

    echo "Executing: $action"
    aws ssm send-command \
        --document-name "llm-app-management" \
        --targets "Key=instanceids,Values=$INSTANCE_ID" \
        --parameters "action=$action,lines=$lines" \
        --region "$REGION" \
        --output table
}

case "${1:-}" in
    status|update|restart|backup|redeploy)
        send_app_command "${1/update/update-images}"
        ;;
    restart-caddy|restart-openwebui|restart-litellm)
        send_app_command "$1"
        ;;
    logs-caddy|logs-openwebui|logs-litellm)
        send_app_command "$1" "${2:-50}"
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
        aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
        ;;
    *)
        usage
        exit 1
        ;;
esac