#!/usr/bin/env bash
#
# destroy.sh -- tear it all down. Empties the buckets first, because
# Terraform CANNOT delete a non-empty versioned bucket.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/terraform"

echo "This will DESTROY all infrastructure in this project."
read -rp "Type 'destroy' to confirm: " ans
[[ "$ans" == "destroy" ]] || { echo "Aborted."; exit 1; }

empty_bucket () {
  local B="$1"
  [[ -z "$B" ]] && return 0
  echo "  Emptying s3://$B ..."
  aws s3 rm "s3://$B" --recursive >/dev/null 2>&1 || true
  # Versioned buckets keep delete markers + old versions. Purge them.
  aws s3api list-object-versions --bucket "$B" --output json \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null \
    | jq -c 'select(.Objects != null)' \
    | while read -r batch; do
        aws s3api delete-objects --bucket "$B" --delete "$batch" >/dev/null 2>&1 || true
      done
  aws s3api list-object-versions --bucket "$B" --output json \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null \
    | jq -c 'select(.Objects != null)' \
    | while read -r batch; do
        aws s3api delete-objects --bucket "$B" --delete "$batch" >/dev/null 2>&1 || true
      done
}

echo "==> Emptying buckets"
empty_bucket "$(terraform output -raw s3_bucket_name 2>/dev/null || true)"
empty_bucket "$(terraform output -raw ssm_transfer_bucket 2>/dev/null || true)"

echo
echo "==> terraform destroy"
terraform plan -destroy
terraform destroy

echo
echo "==> Confirming the expensive things are gone"
echo "  NAT Gateways:"
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId' --output text
echo "  Load Balancers:"
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text
echo "  VPC Endpoints (the 3 SSM interface endpoints cost ~\$22/mo):"
aws ec2 describe-vpc-endpoints --query 'VpcEndpoints[].ServiceName' --output text

echo
echo "Both should print nothing. Don't forget to also terminate the"
echo "Command Node -- Terraform does not manage it (you built it by hand)."
