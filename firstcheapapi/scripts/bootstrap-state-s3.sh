#!/usr/bin/env bash
# Use env so the script finds bash in a portable way.

# Stop the script if a command fails, if a variable is missing, or if a pipeline fails.
set -euo pipefail

# Use AWS_REGION from the environment, or default to us-east-1 if it is not set.
AWS_REGION="${AWS_REGION:-us-east-1}"

# Use PROJECT_NAME from the environment, or default to hello-python-api if it is not set.
PROJECT_NAME="${PROJECT_NAME:-hello-python-api}"

# Use ENVIRONMENT from the environment, or default to dev if it is not set.
ENVIRONMENT="${ENVIRONMENT:-dev}"

# Ask AWS STS for the current account ID so the bucket name is globally unique.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# Build a globally unique S3 bucket name for Terraform state.
STATE_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-tfstate-${ACCOUNT_ID}-${AWS_REGION}"

# Print the bucket name that will be created or reused.
echo "Creating or verifying Terraform state bucket: ${STATE_BUCKET}"

# If the Region is us-east-1, S3 requires create-bucket without LocationConstraint.
if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  # Create the bucket in us-east-1, or continue if it already exists and you own it.
  aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" 2>/dev/null || true
else
  # Create the bucket in non-us-east-1 Regions with a LocationConstraint.
  aws s3api create-bucket --bucket "${STATE_BUCKET}" --region "${AWS_REGION}" --create-bucket-configuration LocationConstraint="${AWS_REGION}" 2>/dev/null || true
fi

# Block all public access settings on the state bucket.
aws s3api put-public-access-block --bucket "${STATE_BUCKET}" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Turn on bucket versioning so older state file versions can be recovered.
aws s3api put-bucket-versioning --bucket "${STATE_BUCKET}" --versioning-configuration Status=Enabled

# Turn on default S3-managed encryption for objects stored in the state bucket.
aws s3api put-bucket-encryption --bucket "${STATE_BUCKET}" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Create a temporary bucket policy file that denies unencrypted HTTP access.
POLICY_FILE="$(mktemp)"

# Write the TLS-only bucket policy JSON to the temporary file.
cat > "${POLICY_FILE}" <<POLICY_JSON
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
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
POLICY_JSON

# Apply the TLS-only bucket policy to the state bucket.
aws s3api put-bucket-policy --bucket "${STATE_BUCKET}" --policy "file://${POLICY_FILE}"

# Delete the temporary policy file from the local computer.
rm -f "${POLICY_FILE}"

# Print the backend configuration values the user should copy into backend.tf.
echo "S3 state bucket is ready."

# Print the bucket name by itself for easy copy and paste.
echo "Bucket: ${STATE_BUCKET}"

# Print the Region by itself for easy copy and paste.
echo "Region: ${AWS_REGION}"

# Print the backend key by itself for easy copy and paste.
echo "Key: ${PROJECT_NAME}/${ENVIRONMENT}/terraform.tfstate"
