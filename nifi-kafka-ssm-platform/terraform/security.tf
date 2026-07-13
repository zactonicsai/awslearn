# security.tf
# ==================================================================
# THE SECURITY MODEL (SSM-ONLY -- NO SSH ANYWHERE)
#
#   Your laptop ──(AWS API, HTTPS 443)──> AWS Systems Manager
#                                              │
#                          SSM Agent polls OUT │ (no inbound!)
#                                              v
#   Internet ──(443 only)──> [ALB SG] ──(8443)──> [NiFi SG]
#                                                     │
#                                                  (9092)
#                                                     v
#                    [Command Node SG] ──(9092)──> [Kafka SG]
#
# THERE IS NO PORT 22. ANYWHERE. IN THIS ENTIRE FILE.
# Search it. You will not find a single `from_port = 22`.
#
# Kafka accepts connections from EXACTLY TWO badges: NiFi and
# Command Node. Nothing else in the universe can reach port 9092.
# ==================================================================

# ------------------------------------------------------------------
# ALB SECURITY GROUP -- the only thing touching the public internet
# ------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public entry point. HTTPS only."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-alb-sg" }

  lifecycle {
    create_before_destroy = true # avoids "SG in use" errors on updates
  }
}

resource "aws_security_group_rule" "alb_in_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr] # <-- ONLY YOU.
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from my IP only"

  # To open NiFi to the world you'd set this to ["0.0.0.0/0"].
  # DON'T. NiFi's UI is a powerful admin console -- someone who
  # reaches it can build a flow that reads your entire S3 bucket.
}

resource "aws_security_group_rule" "alb_in_http_redirect" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP, only to 301-redirect to HTTPS"
}

resource "aws_security_group_rule" "alb_out_to_nifi" {
  type                     = "egress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nifi.id # <-- BADGE, not IP
  security_group_id        = aws_security_group.alb.id
  description              = "ALB -> NiFi only. Nothing else."
}

# ------------------------------------------------------------------
# NIFI SECURITY GROUP
#
# INBOUND: the ALB (8443) and the Command Node (9999 trigger).
#          THAT IS ALL. No SSH. Ansible reaches this host over SSM,
#          which requires ZERO inbound rules.
# ------------------------------------------------------------------
resource "aws_security_group" "nifi" {
  name        = "${local.name}-nifi-sg"
  description = "NiFi. No inbound SSH. Managed via SSM."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-nifi-sg" }

  lifecycle { create_before_destroy = true }
}

# --- NiFi INBOUND (exactly two rules) ---

resource "aws_security_group_rule" "nifi_in_from_alb" {
  type                     = "ingress"
  from_port                = 8443
  to_port                  = 8443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.nifi.id
  description              = "NiFi web UI, from the ALB ONLY"
}

resource "aws_security_group_rule" "nifi_in_http_listener_from_command" {
  type                     = "ingress"
  from_port                = var.nifi_http_listener_port # 9999
  to_port                  = var.nifi_http_listener_port
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id
  security_group_id        = aws_security_group.nifi.id
  description              = "The Python trigger app pokes NiFi here"
}

# ==================================================================
# >>> NOTE WHAT IS *NOT* HERE <<<
#
# There is no port-22 ingress rule for NiFi. There never will be.
# Ansible does not need one. SSM Session Manager works by having the
# SSM Agent (running ON the instance) poll OUTBOUND to the SSM API.
# The connection is established from the inside out. Nothing ever
# needs to connect INTO this host.
#
# This is a strictly stronger posture than "SSH, but only from the
# bastion." There is no SSH daemon exposed to attack at all.
# ==================================================================

# --- NiFi OUTBOUND ---
# Deliberately specific. Unrestricted egress is how a compromised
# host exfiltrates your data. Least privilege applies OUTBOUND too.

resource "aws_security_group_rule" "nifi_out_to_kafka" {
  type                     = "egress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.kafka.id
  security_group_id        = aws_security_group.nifi.id
  description              = "NiFi -> Kafka"
}

resource "aws_security_group_rule" "nifi_out_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nifi.id
  description       = "HTTPS out: SSM Agent, S3 (via endpoint), apt via NAT"
}

resource "aws_security_group_rule" "nifi_out_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.nifi.id
  description       = "HTTP out: Ubuntu apt repos"
}

# ==================================================================
# KAFKA SECURITY GROUP -- THE CENTREPIECE
#
# Requirement: "only allow access from the EC2 command server and
#               nifi on this subnet security group"
#
# TWO ingress rules on 9092. Both use source_security_group_id
# (badges), not cidr_blocks (addresses).
#
# NOT specified anywhere:
#   - 0.0.0.0/0            (the internet)
#   - 10.20.0.0/16         (the whole VPC)
#   - any hardcoded IP
#   - port 22              (there is no SSH in this build)
#
# Therefore: unreachable by anything else. Full stop.
# ==================================================================
resource "aws_security_group" "kafka" {
  name        = "${local.name}-kafka-sg"
  description = "Kafka. Port 9092 open to EXACTLY two SGs. No SSH."
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name}-kafka-sg" }

  lifecycle { create_before_destroy = true }
}

# ==== ALLOWED SOURCE #1: NIFI ====
resource "aws_security_group_rule" "kafka_in_from_nifi" {
  type                     = "ingress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.nifi.id
  security_group_id        = aws_security_group.kafka.id
  description              = "ALLOWED: NiFi may produce to Kafka"
}

# ==== ALLOWED SOURCE #2: THE COMMAND NODE ====
resource "aws_security_group_rule" "kafka_in_from_command_node" {
  type                     = "ingress"
  from_port                = 9092
  to_port                  = 9092
  protocol                 = "tcp"
  source_security_group_id = var.command_node_sg_id
  security_group_id        = aws_security_group.kafka.id
  description              = "ALLOWED: Command Node may consume from Kafka"
}

# ==== THERE IS NO SOURCE #3. AND NO PORT 22. THAT IS THE POINT. ====

# Kafka egress: only what it needs to install itself and reach SSM.
resource "aws_security_group_rule" "kafka_out_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kafka.id
  description       = "HTTPS out: SSM Agent + package downloads"
}

resource "aws_security_group_rule" "kafka_out_http" {
  type              = "egress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.kafka.id
  description       = "HTTP out for apt"
}

# ------------------------------------------------------------------
# VPC ENDPOINT SG
#
# The SSM Interface Endpoints live in the private subnets and need
# to accept HTTPS from the instances. This is what makes SSM work
# WITHOUT the instances having any inbound rules of their own --
# they connect OUT to these endpoints.
# ------------------------------------------------------------------
resource "aws_security_group" "vpce" {
  name        = "${local.name}-vpce-sg"
  description = "Lets private instances reach the SSM/AWS API endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_subnet_cidrs
    description = "HTTPS from private subnets (SSM Agent traffic)"
  }

  tags = { Name = "${local.name}-vpce-sg" }
}
