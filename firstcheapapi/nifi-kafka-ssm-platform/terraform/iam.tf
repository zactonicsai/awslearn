# iam.tf
# ==================================================================
# In an SSM-only build, IAM is not just "nice to have" -- it IS the
# access control mechanism. There is no SSH key to hold. The ONLY
# way onto these boxes is by having IAM permission to start an SSM
# session. That means:
#
#   - Revoking someone's access = removing an IAM permission
#     (instant, central, auditable)
#   - vs. SSH, where revoking = hunting down every copy of a key
#     that may have been emailed, copied, or committed
#
# Every SSM session is logged to CloudTrail with the IAM principal
# who opened it. You cannot get that from SSH.
# ==================================================================

# The "trust policy": WHO is allowed to wear this uniform?
# Answer: an EC2 instance. Nobody else.
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ------------------------------------------------------------------
# Shared policy: access to the SSM transfer bucket.
#
# BOTH NiFi and Kafka need this, because Ansible's aws_ssm connection
# plugin has the TARGET HOST download modules from that bucket.
# Without this permission, every Ansible task fails with AccessDenied
# on the curl step -- a genuinely confusing error, because the SSM
# session itself connects fine.
# ------------------------------------------------------------------
data "aws_iam_policy_document" "ssm_transfer_access" {
  statement {
    sid       = "ListTransferBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.ssm_transfer.arn]
  }

  statement {
    sid    = "ReadWriteTransferObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.ssm_transfer.arn}/*"]
  }
}

resource "aws_iam_policy" "ssm_transfer_access" {
  name        = "${local.name}-ssm-transfer-access"
  description = "Lets managed instances fetch Ansible modules from the SSM transfer bucket"
  policy      = data.aws_iam_policy_document.ssm_transfer_access.json
}

# ==================================================================
# NIFI ROLE
# ==================================================================
resource "aws_iam_role" "nifi" {
  name               = "${local.name}-nifi-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-nifi-role" }
}

# The S3 permissions NiFi needs to actually do its job.
data "aws_iam_policy_document" "nifi_s3" {
  # Permission to LIST the bucket (see what files exist).
  # NOTE: granted on the BUCKET arn, with NO /*
  statement {
    sid       = "ListTheBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.nifi_data.arn]
  }

  # Permission to READ/WRITE the OBJECTS inside it.
  # NOTE: granted on arn + "/*"
  #
  # These are DIFFERENT RESOURCES in IAM's eyes. A bucket and its
  # contents are not the same thing. Put ListBucket on the /* ARN
  # and listing fails with AccessDenied. Two statements. Always.
  statement {
    sid    = "ReadWriteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.nifi_data.arn}/*"]
  }
}

resource "aws_iam_role_policy" "nifi_s3" {
  name   = "${local.name}-nifi-s3-policy"
  role   = aws_iam_role.nifi.id
  policy = data.aws_iam_policy_document.nifi_s3.json
}

# THE key attachment. Without AmazonSSMManagedInstanceCore, the SSM
# Agent cannot register the instance and you have NO WAY IN AT ALL.
# In an SSM-only build there is no SSH fallback. This is mandatory.
resource "aws_iam_role_policy_attachment" "nifi_ssm_core" {
  role       = aws_iam_role.nifi.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "nifi_ssm_transfer" {
  role       = aws_iam_role.nifi.name
  policy_arn = aws_iam_policy.ssm_transfer_access.arn
}

# An "instance profile" is the wrapper that lets an EC2 instance
# actually WEAR a role. Roles can't attach to EC2 directly -- they
# need this container. It's a quirk of IAM. Everyone forgets it once.
resource "aws_iam_instance_profile" "nifi" {
  name = "${local.name}-nifi-profile"
  role = aws_iam_role.nifi.name
}

# ==================================================================
# KAFKA ROLE
# ==================================================================
resource "aws_iam_role" "kafka" {
  name               = "${local.name}-kafka-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = { Name = "${local.name}-kafka-role" }
}

resource "aws_iam_role_policy_attachment" "kafka_ssm_core" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "kafka_ssm_transfer" {
  role       = aws_iam_role.kafka.name
  policy_arn = aws_iam_policy.ssm_transfer_access.arn
}

resource "aws_iam_instance_profile" "kafka" {
  name = "${local.name}-kafka-profile"
  role = aws_iam_role.kafka.name
}

# ==================================================================
# ATTACH THE TRANSFER-BUCKET POLICY TO THE COMMAND NODE'S ROLE TOO
#
# The Command Node is the Ansible CONTROLLER. It has to PUT modules
# into the transfer bucket and start SSM sessions. Its role already
# has AdministratorAccess (from the manual build), so it's covered --
# but if you scope that down later, remember it needs:
#
#   ssm:StartSession, ssm:TerminateSession, ssm:DescribeSessions
#   ssm:SendCommand, ssm:GetCommandInvocation
#   ssm:DescribeInstanceInformation
#   s3:PutObject / GetObject on the transfer bucket
#   ec2:DescribeInstances  (for the dynamic inventory)
#
# See docs/SSM-ONLY.md for a copy-pasteable least-privilege policy.
# ==================================================================
