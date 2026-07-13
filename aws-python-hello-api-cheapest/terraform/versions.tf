# Tell Terraform which Terraform version is expected for this project.
terraform {
  # Require Terraform 1.6 or newer so the syntax and providers work as expected.
  required_version = ">= 1.6.0"

  # List the providers that Terraform must download before it can build this stack.
  required_providers {
    # Configure the AWS provider, which creates AWS resources.
    aws = {
      # Download the AWS provider from the official HashiCorp registry namespace.
      source = "hashicorp/aws"
      # Use version 5 or newer, but stay below version 7 to avoid surprise breaking changes.
      version = ">= 5.0, < 7.0"
    }

    # Configure the archive provider, which zips the Python Lambda file for us.
    archive = {
      # Download the archive provider from the official HashiCorp registry namespace.
      source = "hashicorp/archive"
      # Use version 2 or newer, but stay below version 3 to avoid surprise breaking changes.
      version = ">= 2.4, < 3.0"
    }
  }
}
