#!/usr/bin/env bash
# Optional safety script: copy an existing local terraform.tfstate file to the S3 state bucket.
# Use this only if you started with local state before switching to the S3 backend.
set -euo pipefail

if [[ ! -f terraform.tfstate ]]; then
  echo "No local terraform.tfstate file found. Nothing to back up."
  exit 0
fi

if [[ ! -f backend.tf ]]; then
  echo "backend.tf not found. Run scripts/bootstrap-state-s3.sh first."
  exit 1
fi

BUCKET=$(grep -E 'bucket\s+=' backend.tf | awk -F'"' '{print $2}')
KEY=$(grep -E 'key\s+=' backend.tf | awk -F'"' '{print $2}')
REGION=$(grep -E 'region\s+=' backend.tf | awk -F'"' '{print $2}')
STAMP=$(date +%Y%m%d-%H%M%S)

aws s3 cp terraform.tfstate "s3://${BUCKET}/${KEY}.manual-backup-${STAMP}" --region "$REGION"
echo "Backed up local state to s3://${BUCKET}/${KEY}.manual-backup-${STAMP}"
