# AWS Region where the lab will be created.
variable "aws_region" {
  type        = string
  description = "AWS Region to deploy into, for example us-east-1."
  default     = "us-east-1"
}

# Short project name used in names and tags.
variable "project_name" {
  type        = string
  description = "Short name for this stack. Use lowercase letters, numbers, and hyphens."
  default     = "cloud-team-playbook"
}

# Environment label used for tags and names.
variable "environment" {
  type        = string
  description = "Environment name, such as dev, test, or prod."
  default     = "dev"
}

# Main network range for the VPC.
variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.50.0.0/16"
}

# Public subnets hold the load balancer and NAT Gateway.
variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Two public subnet CIDR blocks."
  default     = ["10.50.1.0/24", "10.50.2.0/24"]
}

# Private subnets hold EC2 instances. They do not receive public IP addresses.
variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Two private subnet CIDR blocks."
  default     = ["10.50.11.0/24", "10.50.12.0/24"]
}

# Only these CIDRs can reach the ALB on port 7777.
variable "allowed_alb_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed to call the public ALB listener on TCP port 7777. Example: [\"203.0.113.10/32\"]."

  validation {
    condition     = length(var.allowed_alb_cidrs) > 0
    error_message = "Set allowed_alb_cidrs to at least one trusted CIDR, usually your public IP with /32."
  }
}

# EC2 size for both the web server and command host.
variable "instance_type" {
  type        = string
  description = "EC2 instance type for the web server and command host."
  default     = "t3.micro"
}

# Optional Route 53 public hosted zone name. Leave empty to skip DNS record creation.
variable "route53_zone_name" {
  type        = string
  description = "Existing public Route 53 hosted zone name, like example.com. Leave empty to skip creating a DNS record."
  default     = ""
}

# Optional DNS name to point to the load balancer. Used only when route53_zone_name is not empty.
variable "route53_record_name" {
  type        = string
  description = "DNS record name, like app.example.com. Used only when route53_zone_name is set."
  default     = "app.example.com"
}
