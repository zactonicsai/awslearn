# s3.tf

resource "random_id" "suffix" {
  byte_length = 4
}

# ==================================================================
# THE DATA BUCKET -- where your .txt files land, and where NiFi
# reads them from.
# ==================================================================
resource "aws_s3_bucket" "nifi_data" {
  bucket = "${local.name}-drop-${random_id.suffix.hex}"
  tags   = { Name = "${local.name}-drop" }
}

resource "aws_s3_bucket_versioning" "nifi_data" {
  bucket = aws_s3_bucket.nifi_data.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "nifi_data" {
  bucket = aws_s3_bucket.nifi_data.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# BLOCK ALL PUBLIC ACCESS. Every "company leaks 100M records"
# headline you have ever read was an S3 bucket without this block.
resource "aws_s3_bucket_public_access_block" "nifi_data" {
  bucket                  = aws_s3_bucket.nifi_data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ==================================================================
# THE SSM TRANSFER BUCKET
#
# WHY DOES THIS EXIST?
#
# Ansible's `community.aws.aws_ssm` connection plugin has to get
# files onto the target host. Over SSH it would use SFTP. Over SSM
# there is no file channel -- SSM only carries a command stream.
#
# So the plugin works like this:
#   1. Ansible uploads the module to THIS bucket (presigned PUT)
#   2. Ansible tells the host, via SSM: "curl this presigned URL"
#   3. The host downloads it from S3 and runs it
#   4. Output comes back over the SSM command channel
#
# That is why an SSM-only Ansible setup needs a bucket and SSH does
# not. It's the price of admission for having no open ports.
# ==================================================================
resource "aws_s3_bucket" "ssm_transfer" {
  bucket        = "${local.name}-ssm-transfer-${random_id.suffix.hex}"
  force_destroy = true # it's a scratch bucket; let terraform destroy clean it

  tags = {
    Name    = "${local.name}-ssm-transfer"
    Purpose = "Ansible aws_ssm connection plugin file transfer"
  }
}

resource "aws_s3_bucket_public_access_block" "ssm_transfer" {
  bucket                  = aws_s3_bucket.ssm_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Auto-delete the scratch files after a day. They're transient.
resource "aws_s3_bucket_lifecycle_configuration" "ssm_transfer" {
  bucket = aws_s3_bucket.ssm_transfer.id

  rule {
    id     = "expire-ansible-scratch"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# ==================================================================
# S3 GATEWAY VPC ENDPOINT
#
# Without this: S3 traffic goes out through the NAT Gateway, onto
#               the public internet, and back. You pay $0.045/GB.
#
# With this:    S3 traffic takes a private road inside AWS. It NEVER
#               touches the internet. And it is completely FREE.
#
# Doubly important in an SSM-only build: the Ansible SSM plugin
# pushes EVERY module through S3. Without this endpoint all of that
# traffic would be billed through the NAT Gateway.
# ==================================================================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # A gateway endpoint works by injecting routes into route tables.
  route_table_ids = [aws_route_table.private.id]

  tags = { Name = "${local.name}-s3-endpoint" }
}

# ==================================================================
# SSM INTERFACE ENDPOINTS -- THE THREE THAT MAKE THIS BUILD WORK
#
# These are NOT optional in an SSM-only design. All three are
# required, and people constantly forget the third:
#
#   ssm          -- the Session Manager / Run Command API itself
#   ssmmessages  -- the WebSocket channel that carries your shell
#   ec2messages  -- the legacy Run Command channel (STILL REQUIRED)
#
# Miss any one and your instance shows up as "Connection lost" in
# the SSM console, or simply never registers at all. This is the
# #1 cause of "SSM doesn't work in my private subnet."
#
# Cost: ~$7.30/mo each, ~$22/mo total. This is the price you pay
# for having zero open ports. It is worth it.
# ==================================================================
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true # <-- MUST be true, or the agent can't resolve the endpoint

  tags = { Name = "${local.name}-${each.key}-endpoint" }
}
