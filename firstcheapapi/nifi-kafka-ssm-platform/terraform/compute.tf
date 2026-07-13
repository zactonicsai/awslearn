# compute.tf
# ==================================================================
# Note what is ABSENT from both instances below:
#
#   key_name = "..."          <-- GONE. No key pair. None exists.
#
# There is no SSH key associated with these hosts. Even if someone
# somehow opened port 22, there would be no authorized_keys entry to
# authenticate against. Access is exclusively via SSM.
# ==================================================================

# Look up the CURRENT Ubuntu 24.04 AMI ID rather than hardcoding one.
# AMI IDs are region-specific AND they change every time Canonical
# publishes a patched image. Hardcoding one means you deploy a stale,
# unpatched OS six months from now.
#
# BONUS: Ubuntu's official AWS AMIs ship with snap-installed
# amazon-ssm-agent preinstalled and enabled. So SSM works out of the
# box. (Amazon Linux 2023 also preinstalls it. Debian and most others
# do NOT -- you'd have to install it in user_data.)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Shared bootstrap. Keep user_data TINY -- debugging it is painful
# (you have to dig through /var/log/cloud-init-output.log, and in an
# SSM-only world you need SSM working before you can even read that).
#
# The ONLY job here is: make absolutely certain the SSM agent is alive.
# If it isn't, you have no way into this box. Ever.
locals {
  ssm_bootstrap = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Ubuntu ships amazon-ssm-agent as a snap. Make sure it's running.
    snap start amazon-ssm-agent || true
    systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true

    # Belt and braces: if the snap is somehow missing, install the deb.
    if ! systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service; then
      snap install amazon-ssm-agent --classic || true
      snap start amazon-ssm-agent || true
    fi

    # Ansible's aws_ssm plugin needs Python 3 on the target.
    apt-get update
    apt-get install -y python3 python3-pip unzip curl

    echo "ssm-ready" > /tmp/bootstrap-done
  EOF
}

# ============================================================
# NIFI
# ============================================================
resource "aws_instance" "nifi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.nifi_instance_type
  subnet_id              = aws_subnet.private[0].id # PRIVATE. No public IP. Ever.
  vpc_security_group_ids = [aws_security_group.nifi.id]
  iam_instance_profile   = aws_iam_instance_profile.nifi.name

  # key_name is DELIBERATELY OMITTED. SSM only.

  root_block_device {
    volume_size           = var.nifi_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Force IMDSv2. Blocks the SSRF class of attack that steals role
  # credentials (this was the vector in the 2019 Capital One breach).
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # <-- the important line
    http_put_response_hop_limit = 1
  }

  user_data = local.ssm_bootstrap

  tags = {
    Name = "${local.name}-nifi"
    Role = "nifi" # <-- Ansible's dynamic inventory finds hosts by this tag
  }
}

# ============================================================
# KAFKA
# ============================================================
resource "aws_instance" "kafka" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.kafka_instance_type
  subnet_id              = aws_subnet.private[0].id # same subnet as NiFi -> lowest latency
  vpc_security_group_ids = [aws_security_group.kafka.id]
  iam_instance_profile   = aws_iam_instance_profile.kafka.name

  # key_name is DELIBERATELY OMITTED. SSM only.

  root_block_device {
    volume_size           = var.kafka_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = local.ssm_bootstrap

  tags = {
    Name = "${local.name}-kafka"
    Role = "kafka"
  }
}
