#!/usr/bin/env bash
# Start an SSM Session Manager shell on the private command host.
set -euo pipefail

AWS_REGION=$(terraform output -raw aws_region)
INSTANCE_ID=$(terraform output -raw command_host_instance_id)

aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION"
