#!/usr/bin/env bash
# Use env so the script finds bash in a portable way.

# Stop the script if a command fails, if a variable is missing, or if a pipeline fails.
set -euo pipefail

# Find the folder where this script lives.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Move from the scripts folder to the Terraform folder.
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

# Print a friendly message so the user knows deployment is starting.
echo "Starting Terraform deploy for the cheapest Python hello API..."

# Change into the Terraform folder so relative paths work correctly.
cd "${TERRAFORM_DIR}"

# Download Terraform providers and prepare the working directory.
terraform init

# Format Terraform files so spacing and indentation are clean.
terraform fmt

# Validate Terraform files before making AWS changes.
terraform validate

# Create a deployment plan file so apply uses the exact reviewed plan.
terraform plan -out=tfplan

# Apply the saved plan and create or update AWS resources.
terraform apply tfplan

# Print the API endpoint after deployment.
terraform output api_endpoint

# Print a friendly message that deployment is finished.
echo "Deploy finished. Run ./scripts/test-api.sh from the project root to test it."
