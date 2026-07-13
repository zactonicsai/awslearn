#!/usr/bin/env bash
# Destroy all resources managed by this Terraform stack.
# The remote state bucket created by bootstrap-state-s3.sh is intentionally NOT destroyed by Terraform.
set -euo pipefail

terraform init
terraform plan -destroy -out=tfplan.destroy

if [[ "${1:-}" == "--auto-approve" ]]; then
  terraform apply tfplan.destroy
else
  echo "Review the destroy plan above. Type DESTROY to continue:"
  read -r ANSWER
  if [[ "$ANSWER" == "DESTROY" ]]; then
    terraform apply tfplan.destroy
  else
    echo "Destroy cancelled."
  fi
fi
