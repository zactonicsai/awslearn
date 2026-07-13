#!/usr/bin/env bash
#
# deploy.sh -- terraform apply, then ansible over SSM.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Terraform"
cd "$ROOT/terraform"
terraform init -upgrade
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan

echo
read -rp "Apply this plan? (yes/no) " ans
[[ "$ans" == "yes" ]] || { echo "Aborted."; exit 1; }
terraform apply tfplan

echo
echo "==> Waiting for the SSM agents to register (~90s)..."
echo "    There is no SSH fallback. If they don't register, Ansible cannot connect."
for i in $(seq 18); do
  ONLINE=$(aws ssm describe-instance-information \
    --query 'length(InstanceInformationList[?PingStatus==`Online`])' \
    --output text 2>/dev/null || echo 0)
  echo "    Online: ${ONLINE}/2"
  [[ "${ONLINE:-0}" -ge 2 ]] && break
  sleep 5
done

echo
echo "==> Ansible (over SSM -- no SSH)"
export ANSIBLE_AWS_SSM_BUCKET="$(terraform -chdir="$ROOT/terraform" output -raw ssm_transfer_bucket)"
export NIFI_FQDN="$(terraform -chdir="$ROOT/terraform" output -raw nifi_url | sed 's|https://||')"
echo "    ANSIBLE_AWS_SSM_BUCKET=$ANSIBLE_AWS_SSM_BUCKET"
echo "    NIFI_FQDN=$NIFI_FQDN"
echo

cd "$ROOT/ansible"
ansible-playbook site.yml

echo
echo "==> Verifying security posture"
bash "$ROOT/scripts/verify-security.sh"

echo
echo "==> Done."
terraform -chdir="$ROOT/terraform" output next_steps
