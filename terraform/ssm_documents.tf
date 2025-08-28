resource "aws_ssm_document" "app_management" {
  name          = "llm-app-management"
  document_type = "Command"
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
      - redeploy
      - logs-caddy
      - logs-openwebui
      - logs-litellm
  lines:
    type: String
    description: 'Number of log lines to show (for logs-* actions)'
    default: '50'
mainSteps:
  - action: aws:runShellScript
    name: executeAction
    inputs:
      timeoutSeconds: '300'
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          ACTION="{{ action }}"
          LINES="{{ lines }}"

          cd /opt/app

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