# network.tf
# ------------------------------------------------------------------
# Builds the new "data VPC" where NiFi and Kafka will live, and
# peers it back to the Command Node's VPC.
# ------------------------------------------------------------------

# Ask AWS which AZs exist right now. Don't hardcode "us-east-1a" --
# not every AZ supports every instance type, and this adapts automatically.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name      = "${var.project_name}-${var.environment}"
  azs       = slice(data.aws_availability_zones.available.names, 0, 2)
  nifi_fqdn = "${var.nifi_subdomain}.${var.domain_name}"
}

# ============================================================
# THE VPC
# ============================================================
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  # Both of these must be true for AWS-internal DNS to work.
  # Without them, your VPC S3 Endpoint silently fails and you will
  # lose an hour wondering why S3 calls time out.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

# ============================================================
# INTERNET GATEWAY -- the door to the internet.
# Attach it to the VPC; a subnet becomes "public" ONLY when its
# route table has a route pointing at this gateway.
# ============================================================
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

# ============================================================
# PUBLIC SUBNETS -- these hold ONLY the load balancer.
# ============================================================
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# ============================================================
# PRIVATE SUBNETS -- NiFi and Kafka live here.
# No route to the internet gateway = unreachable from outside. Period.
# ============================================================
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # NOTE: map_public_ip_on_launch is ABSENT. It defaults to false.
  # That single omission is what makes this subnet private.

  tags = {
    Name = "${local.name}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# ============================================================
# NAT GATEWAY -- lets private servers reach OUT (to download
# NiFi, Java, apt packages) while blocking anything reaching IN.
#
# Think of it as a one-way mirror.
#
# COST WARNING: ~$32/month + $0.045/GB processed. This is the
# single most expensive thing in this build. See the tutorial's
# cost section for cheaper alternatives (Packer-baked AMIs).
# ============================================================
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # NAT itself must sit in a PUBLIC subnet

  tags       = { Name = "${local.name}-nat" }
  depends_on = [aws_internet_gateway.main]
}

# ============================================================
# ROUTE TABLES -- the signposts that decide where packets go.
# ============================================================

# Public route table: "anything not local? -> Internet Gateway"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0" # 0.0.0.0/0 means "literally anywhere"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

# Private route table: "anything not local? -> NAT Gateway"
# NOTE: no route to the Internet Gateway. That's the whole point.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name}-rt-private" }
}

# A route table does nothing until you ASSOCIATE it with a subnet.
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ============================================================
# VPC PEERING -- a private tunnel from the Command Node's VPC
# to the new data VPC.
#
# WHY? Because the requirement says Kafka must be reachable from
# the Command Node. Without peering, the Command Node would have
# to reach Kafka over the public internet, which would mean giving
# Kafka a public IP. We are not doing that. Peering keeps ALL of
# this traffic on Amazon's private backbone -- it never touches
# the internet at all.
#
# Peering has NO hourly charge. You pay only for data transferred.
# ============================================================
resource "aws_vpc_peering_connection" "command_to_data" {
  vpc_id      = var.command_node_vpc_id # requester (Command Node VPC)
  peer_vpc_id = aws_vpc.main.id         # accepter (new data VPC)
  auto_accept = true                    # works because both VPCs are in OUR account

  accepter {
    allow_remote_vpc_dns_resolution = true
  }
  requester {
    allow_remote_vpc_dns_resolution = true
  }

  tags = { Name = "${local.name}-peering" }
}

# A peering connection is just a pipe. Nothing flows until you add
# ROUTES at BOTH ends telling packets to use it. Forgetting one
# direction is the #1 peering mistake -- traffic goes out and the
# reply never comes back.

# Data VPC -> Command VPC
resource "aws_route" "data_to_command" {
  route_table_id            = aws_route_table.private.id
  destination_cidr_block    = var.command_node_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.command_to_data.id
}

# Command VPC -> Data VPC  (we must edit the DEFAULT VPC's route tables)
data "aws_route_tables" "command_vpc" {
  vpc_id = var.command_node_vpc_id
}

resource "aws_route" "command_to_data" {
  count = length(data.aws_route_tables.command_vpc.ids)

  route_table_id            = tolist(data.aws_route_tables.command_vpc.ids)[count.index]
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.command_to_data.id
}
