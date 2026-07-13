# This file pins the Terraform and provider versions for safer repeatable builds.
# Keep this file in Git so your team can review provider version upgrades.
terraform {
  # Terraform 1.10+ is recommended here because the S3 backend can use native lock files.
  required_version = ">= 1.10.0"

  # Providers are plugins Terraform uses to talk to APIs.
  required_providers {
    # The AWS provider creates and manages AWS resources.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }

    # The random provider creates a small random suffix for globally unique S3 bucket names.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6, < 4.0"
    }
  }
}

# The AWS provider tells Terraform what AWS Region to use.
provider "aws" {
  region = var.aws_region

  # Default tags are added to most AWS resources created by this provider.
  default_tags {
    tags = local.common_tags
  }
}
