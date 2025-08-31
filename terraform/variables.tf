variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "ARM64 instance type"
  type        = string
  default     = "t4g.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS size (gp3)"
  type        = number
  default     = 40
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for loguzzo.it"
  type        = string
  default     = "Z0836610DNH179PZSFUU"
}

variable "subdomain" {
  description = "Subdomain to create under the hosted zone"
  type        = string
  default     = "llmao"
}

variable "acme_email" {
  description = "Email for Let's Encrypt/ACME"
  type        = string
  default     = "info@loguzzo.it"
}

variable "github_repo_url" {
  description = "Git SSH URL (e.g., git@github.com:OWNER/REPO.git)"
  type        = string
  default     = "git@github.com:aloguzzo/llmao-aws.git"
}

variable "use_private_repo" {
  description = "If true, bootstrap fetches SSH deploy key from SSM"
  type        = bool
  default     = false
}

variable "ssh_key_name" {
  description = "Optional EC2 key pair for SSH (set null to disable)"
  type        = string
  default     = null
}