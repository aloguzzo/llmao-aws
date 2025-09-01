# CloudWatch Log Groups for system and container logs.
# (Agent can auto-create, but managing them here gives you retention control.)

resource "aws_cloudwatch_log_group" "docker" {
  name              = "/ec2/llm-stack/docker"
  retention_in_days = 30
  tags = {
    Application = "llm-stack"
    Component   = "docker"
  }
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/ec2/llm-stack/system"
  retention_in_days = 30
  tags = {
    Application = "llm-stack"
    Component   = "system"
  }
}
