resource "aws_ssm_document" "app_management" {
  name            = "llm-app-management"
  document_type   = "Command"
  document_format = "YAML"

  content = <<DOC
schemaVersion: '2.2'
description: 'Management commands for LLM application stack'
parameters:
  action:
    type: String
    description: 'Action to perform'
    allowedValues:
      - status
      - update-images
      - restart-stack
      - restart-caddy
      - restart-openwebui
      - restart-litellm
      - backup-volumes
      - list-backups
      - redeploy
      - logs-caddy
      - logs-openwebui
      - logs-litellm
      - setup-cloudwatch
      - cloudwatch-status
  lines:
    type: String
    description: 'Number of log lines to show (for logs-* actions)'
    default: '50'
mainSteps:
  # Detect region (no jq dependency)
  - action: aws:runShellScript
    name: setVars
    inputs:
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail
          if [[ -z "$${AWS_REGION:-}" ]]; then
            TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
            AWS_REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep region | cut -d'"' -f4 || true)
            export AWS_REGION
          fi
          echo "Using AWS_REGION=$${AWS_REGION:-unknown}"

  # Install AmazonCloudWatchAgent package when requested
  - action: aws:configurePackage
    name: installCWAgent
    inputs:
      name: AmazonCloudWatchAgent
      action: Install
      installationType: Uninstall and reinstall
      allowDowngrade: false
    precondition:
      StringEquals:
        - "{{ action }}"
        - "setup-cloudwatch"

  # Fetch config from SSM and start/enable agent
  - action: aws:runShellScript
    name: configCWAgent
    precondition:
      StringEquals:
        - "{{ action }}"
        - "setup-cloudwatch"
    inputs:
      timeoutSeconds: '600'
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          # Re-detect region in this step too (mainSteps don't share env)
          if [[ -z "$${AWS_REGION:-}" ]]; then
            TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)
            AWS_REGION=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep region | cut -d'"' -f4 || true)
            export AWS_REGION
          fi
          : "$${AWS_REGION:?AWS_REGION not set}"

          CONFIG_PATH="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
          mkdir -p "$(dirname "$CONFIG_PATH")"

          echo "[CWAgent] Fetching config from SSM parameter /app/cloudwatch/agent_config"
          aws ssm get-parameter \
            --name "/app/cloudwatch/agent_config" \
            --region "$AWS_REGION" \
            --query 'Parameter.Value' \
            --output text > "$CONFIG_PATH"

          chmod 0644 "$CONFIG_PATH"

          echo "[CWAgent] Enabling and restarting service"
          systemctl daemon-reload || true
          systemctl enable amazon-cloudwatch-agent
          systemctl restart amazon-cloudwatch-agent

          echo "[CWAgent] Status:"
          systemctl is-active amazon-cloudwatch-agent || true
          /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status || true
          journalctl -u amazon-cloudwatch-agent -n 30 --no-pager || true

  # Existing app controls (always runs; include a no-op for setup-cloudwatch)
  - action: aws:runShellScript
    name: executeAction
    inputs:
      timeoutSeconds: '600'
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          ACTION="{{ action }}"
          LINES="{{ lines }}"

          # Short-circuit for setup-cloudwatch so this step doesn't fail
          if [[ "$ACTION" == "setup-cloudwatch" ]]; then
            echo "CloudWatch Agent setup executed in prior steps."
            exit 0
          fi

          cd /opt/app
          export BACKUP_BUCKET="${aws_s3_bucket.backups.id}"

          case "$ACTION" in
            status)
              bash scripts/status.sh
              ;;
            update-images)
              bash scripts/update-images.sh
              ;;
            restart-stack)
              bash scripts/restart-stack.sh
              ;;
            restart-caddy)
              bash scripts/restart-service.sh caddy
              ;;
            restart-openwebui)
              bash scripts/restart-service.sh openwebui
              ;;
            restart-litellm)
              bash scripts/restart-service.sh litellm
              ;;
            backup-volumes)
              bash scripts/backup-volumes.sh
              ;;
            list-backups)
              bash scripts/restore-volumes.sh
              ;;
            redeploy)
              bash scripts/redeploy.sh
              ;;
            logs-caddy)
              cd compose && docker compose logs --tail="$LINES" caddy
              ;;
            logs-openwebui)
              cd compose && docker compose logs --tail="$LINES" openwebui
              ;;
            logs-litellm)
              cd compose && docker compose logs --tail="$LINES" litellm
              ;;
            cloudwatch-status)
              systemctl status --no-pager amazon-cloudwatch-agent || true
              echo "--- agent ctl status ---"
              /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status || true
              ;;
            *)
              echo "Unknown action: $ACTION"
              exit 1
              ;;
          esac
DOC

  tags = {
    Name = "llm-app-management"
  }
}