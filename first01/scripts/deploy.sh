#!/usr/bin/env bash
# Deploy the stack safely with fmt, validate, plan, and apply.
set -euo pipefail

if [[ ! -f backend.tf ]]; then
  echo "backend.tf not found. Run scripts/bootstrap-state-s3.sh first."
  exit 1
fi

if [[ ! -f terraform.tfvars ]]; then
  echo "terraform.tfvars not found. Copy terraform.tfvars.example to terraform.tfvars and edit allowed_alb_cidrs."
  exit 1
fi

terraform init -upgrade
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
terraform output
