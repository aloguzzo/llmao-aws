#!/usr/bin/env pwsh
#Requires -Version 7.0

param(
    [Parameter(Position=0)]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Lines = "50"
)

$ErrorActionPreference = "Stop"

$REGION = "eu-central-1"
$INSTANCE_ID = ""

function Test-SessionManagerPlugin {
    try {
        $null = Get-Command session-manager-plugin -ErrorAction Stop
        return $true
    }
    catch {
        Write-Host "Error: session-manager-plugin is not installed or not in PATH" -ForegroundColor Red
        Write-Host ""
        Write-Host "To install on Windows:"
        Write-Host "  https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-windows.html" -ForegroundColor Yellow
        return $false
    }
}

function Get-InstanceId {
    if ([string]::IsNullOrEmpty($script:INSTANCE_ID)) {
        try {
            $script:INSTANCE_ID = terraform -chdir=terraform output -raw instance_id 2>$null
            if ([string]::IsNullOrEmpty($script:INSTANCE_ID)) {
                throw "Empty instance ID"
            }
        }
        catch {
            Write-Host "Error: Could not get instance ID. Run terraform apply first." -ForegroundColor Red
            exit 1
        }
    }
}

function Show-Usage {
    @"
Usage: .\manage.ps1 <command> [options]

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
  .\manage.ps1 status
  .\manage.ps1 restart-openwebui
  .\manage.ps1 logs-caddy 100
  .\manage.ps1 stop
"@
}

function Invoke-AppCommand {
    param(
        [string]$ScriptCommand
    )

    if (-not (Test-SessionManagerPlugin)) { exit 1 }

    Write-Host "Executing: $ScriptCommand" -ForegroundColor Green
    Write-Host "Starting interactive session..." -ForegroundColor Yellow

    aws ssm start-session --target $INSTANCE_ID --region $REGION --document-name "AWS-StartInteractiveCommand" --parameters "command=`"$ScriptCommand`""
}

Get-InstanceId

switch ($Command) {
    "status" {
        Invoke-AppCommand "cd /opt/app && bash scripts/status.sh"
    }

    "update" {
        Invoke-AppCommand "cd /opt/app && bash scripts/update-images.sh"
    }

    "restart" {
        Invoke-AppCommand "cd /opt/app && bash scripts/restart-stack.sh"
    }

    "restart-caddy" {
        Invoke-AppCommand "cd /opt/app && bash scripts/restart-service.sh caddy"
    }

    "restart-openwebui" {
        Invoke-AppCommand "cd /opt/app && bash scripts/restart-service.sh openwebui"
    }

    "restart-litellm" {
        Invoke-AppCommand "cd /opt/app && bash scripts/restart-service.sh litellm"
    }

    "backup" {
        # Set backup bucket environment variable
        $backupBucket = terraform -chdir=terraform output -raw backup_bucket 2>$null
        if ($backupBucket) {
            Invoke-AppCommand "cd /opt/app && BACKUP_BUCKET=$backupBucket bash scripts/backup-volumes.sh"
        } else {
            Invoke-AppCommand "cd /opt/app && bash scripts/backup-volumes.sh"
        }
    }

    "list-backups" {
        # Set backup bucket environment variable
        $backupBucket = terraform -chdir=terraform output -raw backup_bucket 2>$null
        if ($backupBucket) {
            Invoke-AppCommand "cd /opt/app && BACKUP_BUCKET=$backupBucket bash scripts/restore-volumes.sh"
        } else {
            Invoke-AppCommand "cd /opt/app && bash scripts/restore-volumes.sh"
        }
    }

    "redeploy" {
        Invoke-AppCommand "cd /opt/app && bash scripts/redeploy.sh"
    }

    "logs-caddy" {
        Invoke-AppCommand "cd /opt/app/compose && docker compose logs --tail=$Lines caddy"
    }

    "logs-openwebui" {
        Invoke-AppCommand "cd /opt/app/compose && docker compose logs --tail=$Lines openwebui"
    }

    "logs-litellm" {
        Invoke-AppCommand "cd /opt/app/compose && docker compose logs --tail=$Lines litellm"
    }

    "stop" {
        Write-Host "Stopping instance..." -ForegroundColor Yellow
        aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION
    }

    "start" {
        Write-Host "Starting instance..." -ForegroundColor Yellow
        aws ec2 start-instances --instance-ids $INSTANCE_ID --region $REGION
    }

    "instance-status" {
        aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION `
            --query 'Reservations[0].Instances[0].State.Name' --output text
    }

    "shell" {
        if (-not (Test-SessionManagerPlugin)) { exit 1 }
        aws ssm start-session --target $INSTANCE_ID --region $REGION
    }

    default {
        Show-Usage
        exit 1
    }
}