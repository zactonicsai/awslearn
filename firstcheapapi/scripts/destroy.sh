#!/usr/bin/env bash
# Use env so the script finds bash in a portable way.

# Stop the script if a command fails, if a variable is missing, or if a pipeline fails.
set -euo pipefail

# Find the folder where this script lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Move from the scripts folder to the Terraform folder.
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Print a friendly message so the user knows destroy is starting.
echo "Destroying the Python hello API Terraform stack..."

# Change into the Terraform folder so Terraform can find its state and files.
cd "${TERRAFORM_DIR}"

# Initialize Terraform in case this is a fresh terminal or remote backend is configured.
terraform init

# Show what Terraform plans to delete before it deletes anything.
terraform plan -destroy -out=tfdestroy

# Apply the destroy plan and remove AWS resources created by this stack.
terraform apply tfdestroy

# Print a reminder about the optional remote state bucket.
echo "Destroy finished. Optional S3 state buckets created by bootstrap-state-s3.sh are not deleted by Terraform."
