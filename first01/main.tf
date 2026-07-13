####################################################################################################
# AWS Cloud Team Playbook - Simple VPC + Private EC2 + ALB:7777 + S3-hosted site source + SSM host
#
# Plain-English picture:
# - VPC is the private neighborhood.
# - Public subnets are the front yard where the Load Balancer can be reached.
# - Private subnets are locked rooms where EC2 instances do not get public IPs.
# - The ALB listens on ONE public app port: 7777.
# - The web EC2 listens only to the ALB on port 80.
# - The command EC2 has no inbound network rule; admins connect by AWS SSM Session Manager.
# - An S3 bucket stores the website files. The web EC2 copies those files at boot and serves them.
####################################################################################################

# Get the current AWS account ID. We use it for names and IAM policy ARNs.
data "aws_caller_identity" "current" {}

# Get available Availability Zones in the selected AWS Region.
data "aws_availability_zones" "available" {
  state = "available"
}

# Get the latest Amazon Linux 2023 x86_64 AMI from the AWS public SSM Parameter Store path.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Look up an existing public Route 53 hosted zone only when route53_zone_name is provided.
data "aws_route53_zone" "selected" {
  count        = var.route53_zone_name == "" ? 0 : 1
  name         = var.route53_zone_name
  private_zone = false
}

# Local values are named helper values used across the file.
locals {
  # Keep names short because some AWS resources have name length limits.
  name_prefix = "${var.project_name}-${var.environment}"

  # Select the first two available Availability Zones.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Common tags help cost reporting, ownership, cleanup, and inventory.
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
    Playbook    = "AWS Cloud Team"
  }
}

# Random suffix helps make the S3 asset bucket globally unique.
resource "random_id" "suffix" {
  byte_length = 4
}

####################################################################################################
# Networking: VPC, Internet Gateway, subnets, NAT, and routes
####################################################################################################

# Create the VPC, which is the isolated network boundary for this lab.
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Create an Internet Gateway so public subnets can reach and be reached from the internet.
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Create two public subnets across two Availability Zones for the public Application Load Balancer.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  }
}

# Create two private subnets across two Availability Zones for EC2 instances.
resource "aws_subnet" "private" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  }
}

# Create a public route table for traffic that can go directly to the Internet Gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

# Add the default public route to the Internet Gateway.
resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

# Associate each public subnet with the public route table.
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Allocate a public Elastic IP for the NAT Gateway.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip"
  }
}

# Create one NAT Gateway so private EC2 instances can download packages and reach SSM endpoints.
# Production note: for high availability, use one NAT Gateway per Availability Zone.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${local.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# Create a private route table for instances that should not have public IP addresses.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

# Add the default private route to the NAT Gateway.
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

# Associate each private subnet with the private route table.
resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

####################################################################################################
# Security groups: one public ALB group, one private web group, one private command host group
####################################################################################################

# Security group for the public Application Load Balancer.
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Allow trusted CIDRs to reach the ALB on TCP 7777 only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

# Allow inbound traffic to the ALB only on TCP port 7777 from trusted CIDRs.
resource "aws_vpc_security_group_ingress_rule" "alb_7777" {
  security_group_id = aws_security_group.alb.id
  description       = "Trusted users to ALB app listener on port 7777"
  ip_protocol       = "tcp"
  from_port         = 7777
  to_port           = 7777
  cidr_ipv4         = var.allowed_alb_cidrs[0]
}

# Add extra ALB allowed CIDRs when var.allowed_alb_cidrs has more than one entry.
resource "aws_vpc_security_group_ingress_rule" "alb_7777_extra" {
  for_each = toset(slice(var.allowed_alb_cidrs, 1, length(var.allowed_alb_cidrs)))

  security_group_id = aws_security_group.alb.id
  description       = "Additional trusted CIDR to ALB app listener on port 7777"
  ip_protocol       = "tcp"
  from_port         = 7777
  to_port           = 7777
  cidr_ipv4         = each.value
}

# Allow the ALB to make outbound calls to the private web EC2 target.
resource "aws_vpc_security_group_egress_rule" "alb_all_out" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB outbound traffic to targets"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Security group for the private web EC2 instance.
resource "aws_security_group" "web" {
  name        = "${local.name_prefix}-web-sg"
  description = "Allow web traffic only from the ALB security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-web-sg"
  }
}

# Allow inbound HTTP to the private web EC2 only from the ALB security group.
resource "aws_vpc_security_group_ingress_rule" "web_from_alb" {
  security_group_id            = aws_security_group.web.id
  description                  = "ALB to private web EC2 on port 80"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# Allow the private web EC2 to reach the internet through NAT for package updates and S3/SSM calls.
resource "aws_vpc_security_group_egress_rule" "web_all_out" {
  security_group_id = aws_security_group.web.id
  description       = "Private web host outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Security group for the command host.
resource "aws_security_group" "command" {
  name        = "${local.name_prefix}-command-sg"
  description = "No inbound rules; access is through SSM Session Manager only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-command-sg"
  }
}

# Allow command host outbound traffic so SSM, package downloads, and AWS CLI calls work through NAT.
resource "aws_vpc_security_group_egress_rule" "command_all_out" {
  security_group_id = aws_security_group.command.id
  description       = "Command host outbound traffic"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

####################################################################################################
# S3 site source bucket: private bucket containing index.html and locally hosted CSS
####################################################################################################

# Create a private S3 bucket to store the website files that the private EC2 will copy at boot.
resource "aws_s3_bucket" "site_assets" {
  bucket        = "${local.name_prefix}-site-assets-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-site-assets"
  }
}

# Block all public access because the EC2 web server, not S3, serves the website to users.
resource "aws_s3_bucket_public_access_block" "site_assets" {
  bucket                  = aws_s3_bucket.site_assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable bucket versioning so changes to website files can be recovered.
resource "aws_s3_bucket_versioning" "site_assets" {
  bucket = aws_s3_bucket.site_assets.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption on the S3 bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "site_assets" {
  bucket = aws_s3_bucket.site_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Upload the static HTML file to S3.
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.site_assets.id
  key          = "index.html"
  source       = "${path.module}/site/index.html"
  etag         = filemd5("${path.module}/site/index.html")
  content_type = "text/html"
}

# Upload the local CSS file to S3 so the page does not depend on an internet CDN.
resource "aws_s3_object" "tailwind_css" {
  bucket       = aws_s3_bucket.site_assets.id
  key          = "assets/tailwind-local.css"
  source       = "${path.module}/site/assets/tailwind-local.css"
  etag         = filemd5("${path.module}/site/assets/tailwind-local.css")
  content_type = "text/css"
}

####################################################################################################
# IAM role and instance profile for SSM access and S3 read access
####################################################################################################

# Allow EC2 to assume this IAM role.
resource "aws_iam_role" "ec2_ssm_s3" {
  name = "${local.name_prefix}-ec2-ssm-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-ec2-ssm-s3-role"
  }
}

# Attach AWS managed policy that lets EC2 instances register with AWS Systems Manager.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_s3.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Create least-privilege S3 read access only for the website asset bucket.
resource "aws_iam_policy" "site_assets_read" {
  name        = "${local.name_prefix}-site-assets-read"
  description = "Allow EC2 to read only the S3 website asset bucket."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${aws_s3_bucket.site_assets.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.site_assets.arn
      }
    ]
  })
}

# Attach the S3 read policy to the EC2 role.
resource "aws_iam_role_policy_attachment" "site_assets_read" {
  role       = aws_iam_role.ec2_ssm_s3.name
  policy_arn = aws_iam_policy.site_assets_read.arn
}

# Create the instance profile, which is the wrapper EC2 uses to receive the IAM role.
resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_ssm_s3.name
}

####################################################################################################
# EC2 private web host: serves files copied from S3
####################################################################################################

# Create the private web server EC2 instance.
resource "aws_instance" "web" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data_app.sh.tftpl", {
    aws_region        = var.aws_region
    asset_bucket_name = aws_s3_bucket.site_assets.bucket
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 12
    volume_type = "gp3"
  }

  tags = {
    Name = "${local.name_prefix}-private-web"
    Role = "private-web"
  }

  depends_on = [
    aws_s3_object.index_html,
    aws_s3_object.tailwind_css,
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy_attachment.site_assets_read
  ]
}

####################################################################################################
# EC2 private command host: SSM only, with Terraform and Ansible preinstalled
####################################################################################################

# Create the private command host. There is no SSH key and no inbound security group rule.
resource "aws_instance" "command" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.private[1].id
  vpc_security_group_ids      = [aws_security_group.command.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  user_data = templatefile("${path.module}/user_data_command_host.sh.tftpl", {
    aws_region = var.aws_region
  })

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted   = true
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "${local.name_prefix}-private-command"
    Role = "command-host"
  }

  depends_on = [aws_iam_role_policy_attachment.ssm_core]
}

####################################################################################################
# Application Load Balancer: one public listener on port 7777, forwarding to private EC2 port 80
####################################################################################################

# Create a public Application Load Balancer in the two public subnets.
resource "aws_lb" "app" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# Create the target group for the private web EC2 instance.
resource "aws_lb_target_group" "web" {
  name        = "${local.name_prefix}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# Register the private web EC2 instance with the target group.
resource "aws_lb_target_group_attachment" "web" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web.id
  port             = 80
}

# Create the only public application listener: HTTP on port 7777.
resource "aws_lb_listener" "app_7777" {
  load_balancer_arn = aws_lb.app.arn
  port              = 7777
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

####################################################################################################
# Optional Route 53 DNS alias record
####################################################################################################

# Create an A-record alias to the ALB when route53_zone_name is provided.
# Important: Route 53 maps names to the ALB. The port 7777 control is on the ALB listener, not DNS.
resource "aws_route53_record" "app" {
  count = var.route53_zone_name == "" ? 0 : 1

  zone_id = data.aws_route53_zone.selected[0].zone_id
  name    = var.route53_record_name
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}
