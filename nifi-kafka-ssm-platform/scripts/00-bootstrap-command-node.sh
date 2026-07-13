#!/usr/bin/env bash
#
# 00-bootstrap-command-node.sh
# ============================
# Run this ON the freshly-launched Command Node EC2 instance.
#
# It installs: Terraform, Ansible (+ the aws_ssm connection plugin),
# the AWS CLI v2, the Session Manager plugin, Python + a venv, and
# creates the S3 backend bucket for Terraform state.
#
# HOW YOU GOT HERE (there is no SSH):
#
#   1. Launch a t3.small Ubuntu 24.04 instance
#      - NO key pair (leave it as "Proceed without a key pair")
#      - Security group with NO inbound rules at all
#      - Attach an IAM role with AmazonSSMManagedInstanceCore
#   2. From your laptop:
#        aws ssm start-session --target i-0your-instance-id
#   3. You're in. Run:
#        sudo su - ubuntu
#        curl -O <this script> && bash 00-bootstrap-command-node.sh
#
set -euo pipefail

echo "=============================================="
echo "  COMMAND NODE BOOTSTRAP (SSM-only)"
echo "=============================================="

# ---------------------------------------------------------------
# 0. Prove the IAM role is working BEFORE doing anything else.
#    This is the single best sanity check in AWS.
# ---------------------------------------------------------------
echo
echo "[0/8] Verifying the IAM role..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "  FAIL: no credentials."
  echo "  The instance role isn't attached, or hasn't propagated."
  echo "  EC2 -> Instance -> Actions -> Security -> Modify IAM role"
  exit 1
fi
ARN="$(aws sts get-caller-identity --query Arn --output text)"
echo "  OK: $ARN"
case "$ARN" in
  *assumed-role*) echo "  Good -- this is a ROLE. No keys on disk." ;;
  *) echo "  WARNING: that doesn't look like an assumed role." ;;
esac

# ---------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------
echo
echo "[1/8] Updating the system..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ---------------------------------------------------------------
# 2. Base tools
# ---------------------------------------------------------------
echo
echo "[2/8] Installing base tools..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget unzip git jq \
  python3-pip python3-venv \
  gnupg software-properties-common \
  netcat-openbsd

# ---------------------------------------------------------------
# 3. Terraform, from HashiCorp's official APT repo.
#    (Not a zip download -- this way `apt upgrade` keeps it patched.)
# ---------------------------------------------------------------
echo
echo "[3/8] Installing Terraform..."
if ! command -v terraform >/dev/null 2>&1; then
  wget -qO- https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq terraform
fi
terraform version

# ---------------------------------------------------------------
# 4. Ansible + the AWS collection.
#
#    community.aws is what provides the aws_ssm connection plugin.
#    Without it, Ansible has no way to reach a host without SSH.
# ---------------------------------------------------------------
echo
echo "[4/8] Installing Ansible + the SSM connection plugin..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ansible
sudo apt-get install -y -qq python3-boto3 python3-botocore

ansible-galaxy collection install \
  amazon.aws \
  community.aws \
  community.general

ansible --version | head -1

# ---------------------------------------------------------------
# 5. AWS CLI v2
# ---------------------------------------------------------------
echo
echo "[5/8] Checking the AWS CLI..."
if aws --version 2>&1 | grep -q "aws-cli/1"; then
  echo "  Upgrading v1 -> v2..."
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -q awscliv2.zip
  sudo ./aws/install --update
  rm -rf aws awscliv2.zip
  cd - >/dev/null
fi
aws --version

aws configure set region "${AWS_REGION:-us-east-1}"
aws configure set output json
# NOTE: we did NOT run `aws configure` and paste an access key.
# Only region + output. The credentials come from the IAM role.

# ---------------------------------------------------------------
# 6. Session Manager plugin.
#    REQUIRED for Ansible-over-SSM. This is the piece everyone
#    forgets, and its absence produces a baffling error.
# ---------------------------------------------------------------
echo
echo "[6/8] Installing the Session Manager plugin..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/install-session-manager-plugin.sh" ]]; then
  bash "$SCRIPT_DIR/install-session-manager-plugin.sh"
else
  cd /tmp
  curl -fsSL \
    "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
    -o session-manager-plugin.deb
  sudo dpkg -i session-manager-plugin.deb
  rm -f session-manager-plugin.deb
  cd - >/dev/null
fi
/usr/local/sessionmanagerplugin/bin/session-manager-plugin --version

# ---------------------------------------------------------------
# 7. Python venv.
#
#    Ubuntu 24.04 enforces PEP 668. `pip install` outside a venv
#    fails with "externally-managed-environment". Do NOT use
#    --break-system-packages -- it does exactly what it says.
# ---------------------------------------------------------------
echo
echo "[7/8] Creating the Python virtualenv..."
VENV_DIR="$HOME/.venvs/nifi-kafka"
mkdir -p "$(dirname "$VENV_DIR")"
python3 -m venv "$VENV_DIR"
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
pip install --quiet --upgrade pip
pip install --quiet requests kafka-python boto3
python -c "import kafka, requests, boto3; print('  Python libs OK')"
deactivate

echo "  Activate it later with:  source $VENV_DIR/bin/activate"

# ---------------------------------------------------------------
# 8. S3 bucket for Terraform remote state.
# ---------------------------------------------------------------
echo
echo "[8/8] Creating the Terraform state bucket..."
if [[ -f "$HOME/tf-bucket-name.txt" ]]; then
  BUCKET="$(cat "$HOME/tf-bucket-name.txt")"
  echo "  Reusing existing: $BUCKET"
else
  SUFFIX="$(openssl rand -hex 4)"
  BUCKET="tfstate-cmdnode-${SUFFIX}"

  aws s3api create-bucket --bucket "$BUCKET" --region us-east-1

  # Versioning: every save keeps the old copy, so you can ALWAYS
  # roll back a corrupted state file. Do not skip this.
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  # State files contain secrets. This must NEVER be public.
  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "$BUCKET" > "$HOME/tf-bucket-name.txt"
  echo "  Created: $BUCKET"
fi

# ---------------------------------------------------------------
# Collect the values Terraform needs about THIS instance.
# ---------------------------------------------------------------
echo
echo "=============================================="
echo "  VALUES FOR terraform.tfvars"
echo "=============================================="

TOKEN="$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")"
IID="$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)"

aws ec2 describe-instances --instance-ids "$IID" \
  --query 'Reservations[0].Instances[0].{
      command_node_sg_id:SecurityGroups[0].GroupId,
      command_node_vpc_id:VpcId
    }' --output table

MYIP="$(curl -s https://checkip.amazonaws.com)"
echo
echo "  my_ip_cidr = \"${MYIP}/32\""
echo "  (this is the Command Node's IP -- for the ALB rule, you"
echo "   probably want YOUR LAPTOP's IP instead: curl https://checkip.amazonaws.com)"
echo
echo "  terraform state bucket = $BUCKET"
echo
echo "=============================================="
echo "  NEXT STEPS"
echo "=============================================="
echo "  1. cd terraform"
echo "  2. cp terraform.tfvars.example terraform.tfvars"
echo "  3. Fill in the values printed above"
echo "  4. sed -i \"s/REPLACE_WITH_YOUR_BUCKET/$BUCKET/\" versions.tf"
echo "  5. terraform init && terraform plan -out=tfplan"
echo "  6. READ THE PLAN. Then: terraform apply tfplan"
echo
echo "  There is no SSH key to generate. There never will be."
echo "=============================================="
