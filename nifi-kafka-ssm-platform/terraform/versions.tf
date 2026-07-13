# versions.tf
# ------------------------------------------------------------------
# Pins Terraform + provider versions and configures remote state.
# Pinning matters: without it, a provider releases v6.0 with breaking
# changes overnight and your build spontaneously fails on Monday.
# ------------------------------------------------------------------

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70" # allows 5.70 -> 5.99, blocks 6.0
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in S3, with NATIVE locking (Terraform 1.10+).
  # No DynamoDB table needed anymore.
  #
  # >>> REPLACE the bucket name below, or run:
  # >>>   sed -i "s/REPLACE_WITH_YOUR_BUCKET/$(cat ~/tf-bucket-name.txt)/" versions.tf
  backend "s3" {
    bucket       = "REPLACE_WITH_YOUR_BUCKET"
    key          = "nifi-kafka/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true # <-- the modern way; no DynamoDB
  }
}

provider "aws" {
  region = var.aws_region

  # Tag EVERY resource automatically. Future-you will be grateful when
  # the bill arrives and you can filter by Project.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
    }
  }
}
