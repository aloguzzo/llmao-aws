terraform {
  backend "s3" {
    bucket         = "tfstate-llm-aws-prod-h330zsikdc"
    key            = "state/llm-aws/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "tfstate-lock-llm-aws-prod"
    encrypt        = true
  }
}