#---------------------------------------------------------------
# Public DNS + TLS for the app domain (fully automated).
# - ACM certificate, DNS-validated via Route 53 (no manual steps).
# - The ALB (created by the AWS LB Controller from the app Ingress) discovers
#   this cert automatically by hostname (the Ingress has no hardcoded ARN).
# - Route 53 records for the ALB are created automatically by ExternalDNS
#   (enabled in addons.tf) from the Ingress host — no manual ALIAS.
#---------------------------------------------------------------
variable "app_domain" {
  description = "Public domain the app is served on"
  type        = string
  default     = "claudiq.com"
}

data "aws_route53_zone" "app" {
  name         = "${var.app_domain}."
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  domain_name               = var.app_domain
  subject_alternative_names = ["www.${var.app_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
  tags = local.tags
}

resource "aws_route53_record" "app_cert_validation" {
  for_each = {
    for o in aws_acm_certificate.app.domain_validation_options : o.domain_name => {
      name = o.resource_record_name
      type = o.resource_record_type
      rec  = o.resource_record_value
    }
  }
  zone_id         = data.aws_route53_zone.app.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.rec]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.app_cert_validation : r.fqdn]
}

output "app_certificate_arn" {
  description = "ACM certificate ARN for the app domain"
  value       = aws_acm_certificate.app.arn
}
