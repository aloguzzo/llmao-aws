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

function Send-AppCommand {
    param(
        [string]$Action,
        [string]$LogLines = "50"
    )

    Write-Host "Executing: $Action" -ForegroundColor Green
    aws ssm send-command `
        --document-name "llm-app-management" `
        --targets "Key=instanceids,Values=$INSTANCE_ID" `
        --parameters "action=$Action,lines=$LogLines" `
        --region $REGION `
        --output table
}

# Check prerequisites
if (-not (Test-SessionManagerPlugin)) {
    exit 1
}

Get-InstanceId

switch ($Command) {
    { $_ -in @("status", "update", "restart", "backup", "redeploy") } {
        $action = if ($_ -eq "update") { "update-images" } else { $_ }
        Send-AppCommand -Action $action
    }

    { $_ -in @("restart-caddy", "restart-openwebui", "restart-litellm") } {
        Send-AppCommand -Action $_
    }

    { $_ -in @("logs-caddy", "logs-openwebui", "logs-litellm") } {
        Send-AppCommand -Action $_ -LogLines $Lines
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
        aws ssm start-session --target $INSTANCE_ID --region $REGION
    }

    "list-backups" {
        Send-AppCommand -Action "list-backups"
    }

    default {
        Show-Usage
        exit 1
    }
}