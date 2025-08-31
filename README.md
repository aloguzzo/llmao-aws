# llmao-aws — OpenWebUI + LiteLLM on AWS EC2

Single-instance deployment of OpenWebUI with LiteLLM proxy, fronted by Caddy with automatic HTTPS. Fully automated provisioning via Terraform with S3 backups and SSM-based management.

## What This Deploys

- **EC2 Instance**: t4g.medium (ARM64) running Ubuntu 24.04
- **OpenWebUI**: Web interface at https://llmao.loguzzo.it
- **LiteLLM**: Internal OpenAI-compatible proxy
- **Caddy**: Reverse proxy with automatic Let's Encrypt TLS
- **Route 53**: Automatic DNS record creation
- **S3 Backup**: Automated volume backups with lifecycle management
- **SSM Management**: Remote access and operations without SSH

**Domain**: llmao.loguzzo.it
**Region**: eu-central-1
**Estimated Cost**: ~$35 USD/month

## Prerequisites

- AWS account with appropriate permissions
- Route 53 hosted zone for `loguzzo.it`
- Terraform 1.13+ and AWS CLI v2

## Repository Access

This project supports both public and private GitHub repositories:

### Public Repository (Default)
- Uses HTTPS clone: `https://github.com/aloguzzo/llmao-aws.git`
- No additional setup required
- Set `use_private_repo = false` (default)

### Private Repository
- Uses SSH clone: `git@github.com:aloguzzo/llmao-aws.git`
- Requires deploy key setup in SSM Parameter Store
- Set `use_private_repo = true`
- Store deploy key in: `/app/github/deploy_key_priv`

## Quick Start

### 1. Setup Remote State

```bash
aws configure set default.region eu-central-1

# Create S3 bucket for Terraform state
aws s3api head-bucket --bucket tfstate-llm-aws-prod-h330zsikdc || \
aws s3api create-bucket --bucket tfstate-llm-aws-prod-h330zsikdc --region eu-central-1 --create-bucket-configuration LocationConstraint=eu-central-1

aws s3api put-bucket-versioning --bucket tfstate-llm-aws-prod-h330zsikdc --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket tfstate-llm-aws-prod-h330zsikdc --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Create DynamoDB lock table
aws dynamodb describe-table --table-name tfstate-lock-llm-aws-prod >/dev/null 2>&1 || \
aws dynamodb create-table \
  --table-name tfstate-lock-llm-aws-prod \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region eu-central-1
```

### 2. Configure Secrets

Store required secrets in AWS SSM Parameter Store:

```bash
# OpenAI API key (required)
aws ssm put-parameter \
  --name "/app/litellm/openai_api_key" \
  --type "SecureString" \
  --value "sk-YOUR_OPENAI_KEY" \
  --overwrite \
  --region eu-central-1

# GitHub deploy key (only needed for private repositories)
# Skip this if using public repository
aws ssm put-parameter \
  --name "/app/github/deploy_key_priv" \
  --type "SecureString" \
  --value "$(cat ./your-deploy-key)" \
  --overwrite \
  --region eu-central-1
```

### 3. Deploy

```bash
cd terraform
terraform init

# For public repo (default):
terraform apply \
  -var 'github_repo_url=https://github.com/aloguzzo/llmao-aws.git' \
  -var 'acme_email=info@loguzzo.it' \
  -var 'subdomain=llmao'

# For private repo (explicit override):
terraform apply \
  -var 'github_repo_url=git@github.com:aloguzzo/llmao-aws.git' \
  -var 'acme_email=info@loguzzo.it' \
  -var 'subdomain=llmao' \
  -var 'use_private_repo=true'
```

### 4. Verify

```bash
# Check DNS resolution
terraform output public_ip
dig +short llmao.loguzzo.it

# Access the application
open https://llmao.loguzzo.it
```

## Management

Install session manager plugin first:
- **macOS**: [Install on macOS](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-macos-overview.html)
- **Windows**: [Install on Windows](https://docs.aws.amazon.com/systems-manager/latest/userguide/install-plugin-windows.html)

### Using Management Scripts

```zsh
# macOS
./manage.zsh status
./manage.zsh backup
./manage.zsh restart-openwebui
```

```powershell
# Windows
.\manage.ps1 status
.\manage.ps1 backup
.\manage.ps1 restart-openwebui
```

### Available Commands

| Command                | Description                                            |
|------------------------|--------------------------------------------------------|
| `status`               | Show application and system status                     |
| `update`               | Update Docker images                                   |
| `restart`              | Restart entire stack                                   |
| `restart-SERVICE`      | Restart individual service (caddy, openwebui, litellm) |
| `backup`               | Backup volumes to S3                                   |
| `list-backups`         | Show available S3 backups                              |
| `redeploy`             | Pull latest code and restart                           |
| `logs-SERVICE [lines]` | Show service logs                                      |
| `stop/start`           | Control EC2 instance                                   |
| `shell`                | Interactive SSM session                                |

### Direct AWS CLI

```bash
# Interactive shell
aws ssm start-session --target $(terraform output -raw instance_id) --region eu-central-1

# Execute commands
aws ssm send-command \
  --document-name "llm-app-management" \
  --targets "Key=instanceids,Values=$(terraform output -raw instance_id)" \
  --parameters action=status \
  --region eu-central-1
```

## Configuration

### Terraform Variables

| Variable          | Default                                 | Description                |
|-------------------|-----------------------------------------|----------------------------|
| `aws_region`      | `eu-central-1`                          | AWS region                 |
| `instance_type`   | `t4g.medium`                            | EC2 instance type          |
| `subdomain`       | `llmao`                                 | Subdomain under loguzzo.it |
| `acme_email`      | `info@loguzzo.it`                       | Let's Encrypt email        |
| `github_repo_url` | `git@github.com:aloguzzo/llmao-aws.git` | Repository URL             |

### OpenWebUI Setup

After deployment:
1. Visit https://llmao.loguzzo.it
2. Create admin account
3. Set API Base URL to `http://litellm:4000`
4. Configure authentication as needed

## Architecture Details

- **Networking**: Default VPC with public subnet, security group allows 80/443 only
- **Storage**: Docker volumes on root EBS (40GB gp3), S3 backups with lifecycle management
- **Security**: No SSH access, SSM Session Manager only, secrets in Parameter Store
- **Monitoring**: CloudWatch logs, Docker health checks
- **Backup**: Automated S3 backups, 30-day retention → Standard-IA → Glacier → deletion after 1 year

## Repository Structure

```
├── terraform/           # Infrastructure as code
├── compose/             # Docker Compose configuration
├── caddy/               # Reverse proxy config
├── scripts/             # Management and backup scripts
├── manage.zsh           # macOS management script
└── manage.ps1           # Windows management script
```

## Security Notes

- No SSH keys or ports exposed
- All secrets encrypted in SSM Parameter Store
- Automatic TLS certificate management
- IAM roles with minimal required permissions
- Private GitHub repository support

## Costs (eu-central-1)

- EC2 t4g.medium: ~$30/month
- EBS 40GB gp3: ~$4/month
- S3 backups: ~$1/month (minimal usage)
- Route 53: Existing hosted zone, one A record

**Total**: ~$35 USD/month

## License

MIT