# Default VPC and default public subnet
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_caller_identity" "current" {}

# Ubuntu 24.04 LTS ARM64
data "aws_ami" "ubuntu_2404_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
  filter {
    name = "image-id"
    values = ["ami-0ed1e06189d76073f"]
  }
}

# Security group: only 80/443 open
resource "aws_security_group" "app" {
  name        = "llm-single-ec2-sg"
  description = "HTTP/HTTPS only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description      = "HTTP"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  ingress {
    description      = "HTTPS"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "All egress"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "llm-single-ec2-sg" }
}

# IAM role and instance profile for SSM + SSM Parameter read
data "aws_iam_policy_document" "ec2_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "llm-single-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

# Managed policy for SSM (Session Manager)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow reads of /app/* SSM parameters + decryption
resource "aws_iam_policy" "ssm_params_read" {
  name        = "llm-single-ec2-ssm-params-read"
  description = "Read /app/* parameters from SSM Parameter Store"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"],
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/app/*"
      },
      {
        Effect   = "Allow",
        Action   = ["kms:Decrypt"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_params_read_attach" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ssm_params_read.arn
}

resource "aws_iam_instance_profile" "ec2" {
  name = "llm-single-ec2-profile"
  role = aws_iam_role.ec2.name
}

# EC2 instance
locals {
  fqdn = "${var.subdomain}.loguzzo.it"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.ubuntu_2404_arm64.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnets.default_public.ids[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  key_name                    = var.ssh_key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size_gb
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/user_data/bootstrap.sh.tpl", {
    domain_name     = local.fqdn
    acme_email      = var.acme_email
    aws_region      = var.aws_region
    github_repo_url = var.github_repo_url
    use_private     = var.use_private_repo
  })

  tags = { Name = "llm-single-ec2" }
}

# Route 53 A record -> instance public IP
resource "aws_route53_record" "llmao" {
  zone_id = var.hosted_zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.app.public_ip]
}