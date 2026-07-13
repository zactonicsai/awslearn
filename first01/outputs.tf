# Public DNS name of the ALB.
output "alb_dns_name" {
  description = "Public ALB DNS name. Use port 7777."
  value       = aws_lb.app.dns_name
}

# Easy test URL using the ALB DNS name.
output "app_url" {
  description = "App URL through the ALB listener on port 7777."
  value       = "http://${aws_lb.app.dns_name}:7777"
}

# Optional Route 53 URL if DNS was configured.
output "route53_url" {
  description = "Route 53 URL if route53_zone_name was set."
  value       = var.route53_zone_name == "" ? "Route 53 record skipped" : "http://${var.route53_record_name}:7777"
}

# Private S3 bucket that stores the static website source files.
output "site_asset_bucket" {
  description = "Private S3 bucket holding index.html and local CSS."
  value       = aws_s3_bucket.site_assets.bucket
}

# Private web server EC2 instance ID.
output "web_instance_id" {
  description = "Private EC2 instance serving the hello world website."
  value       = aws_instance.web.id
}

# Private command host EC2 instance ID.
output "command_host_instance_id" {
  description = "Private EC2 command host instance ID for SSM Session Manager."
  value       = aws_instance.command.id
}

# Copy/paste command to connect to the private command host.
output "ssm_start_session_command" {
  description = "AWS CLI command to start a Session Manager shell on the command host."
  value       = "aws ssm start-session --target ${aws_instance.command.id} --region ${var.aws_region}"
}

# AWS Region used for this stack.
output "aws_region" {
  description = "AWS Region used by this Terraform stack."
  value       = var.aws_region
}
