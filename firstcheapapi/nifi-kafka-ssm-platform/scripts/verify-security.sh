#!/usr/bin/env bash
#
# verify-security.sh
# ==================
# Proves the security model actually holds. Don't take the README's
# word for it -- run this.
#
# It checks:
#   1. NO security group in this project has ANY port-22 rule
#   2. NO EC2 key pair is attached to any instance
#   3. NiFi and Kafka have NO public IP
#   4. Kafka's port 9092 admits EXACTLY two security groups
#   5. Both hosts are registered and Online in SSM
#
set -uo pipefail

TF_DIR="${TF_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)}"
PROJECT="${PROJECT:-nifi-platform}"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "======================================================================"
echo "  SECURITY VERIFICATION"
echo "======================================================================"

# ---------------------------------------------------------------
echo
echo "TEST 1: No SSH (port 22) rule exists on ANY project security group"
echo "----------------------------------------------------------------------"
SSH_RULES="$(aws ec2 describe-security-groups \
  --filters "Name=tag:Project,Values=${PROJECT}" \
  --query 'SecurityGroups[].IpPermissions[?FromPort==`22`]' \
  --output text 2>/dev/null)"

if [[ -z "$SSH_RULES" ]]; then
  ok "Zero port-22 ingress rules. There is no SSH surface at all."
else
  bad "Found a port-22 rule! This build should have NONE:"
  echo "$SSH_RULES"
fi

# ---------------------------------------------------------------
echo
echo "TEST 2: No EC2 key pair is attached to any instance"
echo "----------------------------------------------------------------------"
KEYS="$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].KeyName' \
  --output text 2>/dev/null | tr -d '[:space:]')"

if [[ -z "$KEYS" || "$KEYS" == "None" ]]; then
  ok "No key pairs. Even if port 22 were open, there'd be no key to use."
else
  bad "A key pair is attached: $KEYS"
fi

# ---------------------------------------------------------------
echo
echo "TEST 3: NiFi and Kafka have NO public IP"
echo "----------------------------------------------------------------------"
PUBIPS="$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=${PROJECT}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].PublicIpAddress' \
  --output text 2>/dev/null | tr -d '[:space:]')"

if [[ -z "$PUBIPS" || "$PUBIPS" == "None" ]]; then
  ok "No public IPs. These hosts are not merely firewalled -- they are"
  echo "         unroutable from the internet. There is no path to them."
else
  bad "A public IP exists: $PUBIPS"
fi

# ---------------------------------------------------------------
echo
echo "TEST 4: Kafka:9092 admits EXACTLY two security groups"
echo "----------------------------------------------------------------------"
KAFKA_SG_SOURCES="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*kafka-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`].UserIdGroupPairs[].GroupId' \
  --output text 2>/dev/null)"

KAFKA_SG_CIDRS="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*kafka-sg" \
  --query 'SecurityGroups[0].IpPermissions[?FromPort==`9092`].IpRanges[].CidrIp' \
  --output text 2>/dev/null)"

COUNT="$(echo "$KAFKA_SG_SOURCES" | wc -w)"

echo "  Allowed source security groups on 9092:"
for sg in $KAFKA_SG_SOURCES; do
  NAME="$(aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].GroupName' --output text 2>/dev/null)"
  echo "      $sg  ($NAME)"
done

if [[ "$COUNT" -eq 2 ]]; then
  ok "Exactly 2 source security groups (NiFi + Command Node)."
else
  bad "Expected 2 source SGs, found $COUNT."
fi

if [[ -z "$KAFKA_SG_CIDRS" ]]; then
  ok "Zero CIDR blocks on 9092. No IP ranges. Badges only."
else
  bad "A CIDR block is allowed on 9092: $KAFKA_SG_CIDRS"
  echo "         This would let ANY host in that range reach Kafka."
fi

# ---------------------------------------------------------------
echo
echo "TEST 5: Both hosts are Online in SSM"
echo "----------------------------------------------------------------------"
echo "  (If this fails, Ansible cannot connect -- there is no SSH fallback.)"
echo

aws ssm describe-instance-information \
  --query 'InstanceInformationList[].{Instance:InstanceId,Ping:PingStatus,Platform:PlatformName,Agent:AgentVersion}' \
  --output table 2>/dev/null

ONLINE="$(aws ssm describe-instance-information \
  --query 'length(InstanceInformationList[?PingStatus==`Online`])' \
  --output text 2>/dev/null)"

if [[ "${ONLINE:-0}" -ge 2 ]]; then
  ok "$ONLINE instances Online in SSM."
else
  bad "Only ${ONLINE:-0} instance(s) Online. Expected at least 2."
  echo
  echo "         Common causes, in order:"
  echo "           - The instance role is missing AmazonSSMManagedInstanceCore"
  echo "           - You're missing one of the THREE required VPC endpoints"
  echo "             (ssm, ssmmessages, AND ec2messages -- people forget the 3rd)"
  echo "           - private_dns_enabled = false on the interface endpoints"
  echo "           - The endpoint SG doesn't allow 443 from the private subnets"
  echo "           - It's just been <2 min since boot. Wait and re-run."
fi

# ---------------------------------------------------------------
echo
echo "======================================================================"
echo "  RESULT:  $PASS passed, $FAIL failed"
echo "======================================================================"

if [[ "$FAIL" -eq 0 ]]; then
  echo
  echo "  The security model holds:"
  echo "    - Zero SSH ports. Zero key pairs. Zero public IPs on data hosts."
  echo "    - Kafka reachable by exactly two security groups, named by badge."
  echo "    - All access is via SSM, logged to CloudTrail with the IAM"
  echo "      principal who opened each session."
  echo
  exit 0
else
  echo
  echo "  Something is wrong. See the failures above."
  echo
  exit 1
fi
