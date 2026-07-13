# variables.tf
# ------------------------------------------------------------------
# Variables are the "settings menu" of your infrastructure.
# Values come from terraform.tfvars.
# ------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to build in"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name, used as a prefix on every resource"
  type        = string
  default     = "nifi-platform"
}

variable "environment" {
  description = "dev / staging / prod"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Who owns this (for tags/billing)"
  type        = string
}

# ---------- NETWORK ----------

variable "vpc_cidr" {
  description = "Address range for the NEW data VPC"
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be valid CIDR notation, e.g. 10.20.0.0/16"
  }
}

variable "public_subnet_cidrs" {
  description = "Two public subnets (required: ALB needs 2 AZs)"
  type        = list(string)
  default     = ["10.20.1.0/24", "10.20.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "An ALB requires at least 2 subnets in 2 different AZs."
  }
}

variable "private_subnet_cidrs" {
  description = "Two private subnets (NiFi + Kafka live here)"
  type        = list(string)
  default     = ["10.20.11.0/24", "10.20.12.0/24"]
}

# ---------- COMMAND NODE (the box you're sitting on) ----------

variable "command_node_sg_id" {
  description = "Security Group ID of the Command Node. From Part One, Step 15."
  type        = string

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.command_node_sg_id))
    error_message = "Must look like sg-0a1b2c3d4e5f67890"
  }
}

variable "command_node_vpc_id" {
  description = "VPC ID the Command Node lives in (usually your default VPC)"
  type        = string
}

variable "command_node_vpc_cidr" {
  description = "CIDR of the Command Node's VPC. Default VPC is usually 172.31.0.0/16"
  type        = string
  default     = "172.31.0.0/16"
}

# ---------- DOMAIN ----------

variable "domain_name" {
  description = "Your root domain, e.g. example.com"
  type        = string
}

variable "nifi_subdomain" {
  description = "Subdomain NiFi will live at"
  type        = string
  default     = "nifi"
}

variable "route53_zone_id" {
  description = "Route53 Hosted Zone ID for your domain"
  type        = string
}

# ---------- ACCESS ----------

variable "my_ip_cidr" {
  description = "Your public IP with /32. Who may reach the ALB."
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "Must be CIDR, e.g. 203.0.113.45/32"
  }
}

# NOTE: there is deliberately NO ssh_key_name variable.
# This build uses AWS Systems Manager Session Manager exclusively.
# No key pairs are created, no port 22 is ever opened, and no SSH
# daemon is ever reachable. See docs/SSM-ONLY.md.

# ---------- SIZING ----------

variable "nifi_instance_type" {
  description = "NiFi is a JVM app. Give it RAM."
  type        = string
  default     = "t3.large"
}

variable "kafka_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "nifi_volume_size" {
  description = "GB. NiFi's repositories eat disk."
  type        = number
  default     = 100
}

variable "kafka_volume_size" {
  description = "GB. Kafka logs eat disk."
  type        = number
  default     = 100
}

# ---------- APP CONFIG ----------

variable "kafka_topic" {
  type    = string
  default = "nifi-s3-files"
}

variable "nifi_http_listener_port" {
  description = "Port where NiFi listens for our Python trigger"
  type        = number
  default     = 9999
}
