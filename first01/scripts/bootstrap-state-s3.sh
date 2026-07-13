#!/usr/bin/env bash
# Create a safe S3 bucket for Terraform state and generate backend.tf.
# Run this before terraform init.
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-cloud-team-playbook}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE_ARG=()

if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_PROFILE_ARG=(--profile "$AWS_PROFILE")
fi

ACCOUNT_ID=$(aws sts get-caller-identity "${AWS_PROFILE_ARG[@]}" --query Account --output text)
STATE_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${ACCOUNT_ID}-${AWS_REGION}"
STATE_KEY="env/${ENVIRONMENT}/${PROJECT_NAME}.tfstate"

printf 'Creating/checking state bucket: %s\n' "$STATE_BUCKET"

if [[ "$AWS_REGION" == "us-east-1" ]]; then
  aws s3api create-bucket \
    "${AWS_PROFILE_ARG[@]}" \
    --bucket "$STATE_BUCKET" \
    --region "$AWS_REGION" 2>/dev/null || true
else
  aws s3api create-bucket \
    "${AWS_PROFILE_ARG[@]}" \
    --bucket "$STATE_BUCKET" \
    --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" 2>/dev/null || true
fi

aws s3api put-public-access-block \
  "${AWS_PROFILE_ARG[@]}" \
  --bucket "$STATE_BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning \
  "${AWS_PROFILE_ARG[@]}" \
  --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  "${AWS_PROFILE_ARG[@]}" \
  --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-bucket-policy \
  "${AWS_PROFILE_ARG[@]}" \
  --bucket "$STATE_BUCKET" \
  --policy "$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ],
      "Condition": {
        "Bool": { "aws:SecureTransport": "false" }
      }
    }
  ]
}
POLICY
)"

cat > backend.tf <<BACKEND
terraform {
  backend "s3" {
    bucket       = "${STATE_BUCKET}"
    key          = "${STATE_KEY}"
    region       = "${AWS_REGION}"
    encrypt      = true
    use_lockfile = true
  }
}
BACKEND

printf '\nbackend.tf created. Next run:\n'
printf '  terraform init\n'
printf '\nState bucket: s3://%s/%s\n' "$STATE_BUCKET" "$STATE_KEY"
