# alb.tf
# The ALB is unaffected by the SSM-only decision. It was never
# reachable via SSH anyway -- it's a managed AWS service.

# ---------- TLS CERTIFICATE (free, from AWS) ----------
resource "aws_acm_certificate" "nifi" {
  domain_name       = local.nifi_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-cert" }
}

# ACM proves you own the domain by asking you to create a specific
# DNS record. Since Terraform manages Route53 too, it does this for
# you automatically. One of Terraform's genuinely nicest tricks.
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.nifi.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Blocks Terraform until AWS confirms the certificate is issued.
# Typically 30 seconds to 2 minutes.
resource "aws_acm_certificate_validation" "nifi" {
  certificate_arn         = aws_acm_certificate.nifi.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- THE LOAD BALANCER ----------
resource "aws_lb" "nifi" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  internal           = false # false = internet-facing
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id # <-- the two AZs. Required.

  enable_deletion_protection = false # set TRUE in production!
  drop_invalid_header_fields = true  # security hardening
  idle_timeout               = 300   # NiFi's UI holds long connections

  tags = { Name = "${local.name}-alb" }
}

# ---------- TARGET GROUP: "who is behind the door?" ----------
resource "aws_lb_target_group" "nifi" {
  name        = "${local.name}-nifi-tg"
  port        = 8443
  protocol    = "HTTPS" # NiFi speaks HTTPS internally
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    enabled             = true
    path                = "/nifi-api/system-diagnostics"
    protocol            = "HTTPS"
    matcher             = "200,401" # 401 = "NiFi is UP but wants auth". That IS healthy!
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }

  # NiFi's UI is stateful -- keep a user pinned to one node.
  stickiness {
    enabled         = true
    type            = "lb_cookie"
    cookie_duration = 86400
  }

  tags = { Name = "${local.name}-nifi-tg" }
}

resource "aws_lb_target_group_attachment" "nifi" {
  target_group_arn = aws_lb_target_group.nifi.arn
  target_id        = aws_instance.nifi.id
  port             = 8443
}

# ---------- LISTENERS ----------

# Port 80: don't serve anything, just bounce people to HTTPS
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.nifi.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Port 443: the real one
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.nifi.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06" # modern TLS 1.2/1.3 only
  certificate_arn   = aws_acm_certificate_validation.nifi.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nifi.arn
  }
}

# ---------- DNS ----------
# An ALIAS record (not a CNAME). ALIAS is AWS-specific, free to query,
# and unlike a CNAME it can live at the zone apex. Always prefer ALIAS
# when pointing at an AWS resource.
resource "aws_route53_record" "nifi" {
  zone_id = var.route53_zone_id
  name    = local.nifi_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.nifi.dns_name
    zone_id                = aws_lb.nifi.zone_id
    evaluate_target_health = true
  }
}
