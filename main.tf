############################################
# ACTIVITY 1 - BASIC SETUP (S3 + CLOUDFRONT)
############################################

############################################
# PROVIDER
############################################
provider "aws" {
  region = "ap-southeast-1"
}

############################################
# VARIABLES
############################################
variable "bucket_name" {
  default = "arista-cloudfront"
}

############################################
# S3 BUCKET (PRIVATE)
############################################
resource "aws_s3_bucket" "site" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "block" {
  bucket = aws_s3_bucket.site.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

############################################
# ORIGIN ACCESS CONTROL (OAC)
############################################
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "oac-${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

############################################
# CLOUDFRONT DISTRIBUTION (NO DOMAIN, NO HTTPS YET)
############################################
resource "aws_cloudfront_distribution" "cf" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin"

    viewer_protocol_policy = "allow-all"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

############################################
# S3 BUCKET POLICY (ALLOW CLOUDFRONT ONLY)
############################################
data "aws_iam_policy_document" "bucket_policy" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cf_full.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "policy" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}






############################################
# ACTIVITY 2 - FULL SETUP (DOMAIN + HTTPS + WAF)
############################################

############################################
# SECOND PROVIDER FOR ACM
############################################
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

variable "domain_name" {
  default = "arista-cloudfront.sctp-sandbox.com"
}

############################################
# ACM CERTIFICATE
############################################
resource "aws_acm_certificate" "cert" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
}

############################################
# ROUTE53 ZONE
############################################
data "aws_route53_zone" "zone" {
  name = "sctp-sandbox.com"
}

############################################
# CERT VALIDATION RECORD
############################################
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.zone.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.value]
}

resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

############################################
# UPDATE CLOUDFRONT FOR HTTPS + DOMAIN + WAF
############################################

  resource "aws_wafv2_web_acl" "waf" {
  provider = aws.us_east_1
  name  = "cf-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "cf-waf"
    sampled_requests_enabled   = true
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }
}

############################################
# UPDATE CLOUDFRONT SETTINGS
############################################
resource "aws_cloudfront_distribution" "cf_full" {
  enabled             = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "s3-origin"

    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
  }

  web_acl_id = aws_wafv2_web_acl.waf.arn

  aliases = [var.domain_name]

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
}


############################################
# ROUTE53 ALIAS RECORD
############################################
resource "aws_route53_record" "alias" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cf_full.domain_name
    zone_id                = aws_cloudfront_distribution.cf_full.hosted_zone_id
    evaluate_target_health = false
  }
}


############################################
# OUTPUTS
############################################

output "s3_bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.cf.id
}

output "cloudfront_domain_name_activity1" {
  value = aws_cloudfront_distribution.cf.domain_name
}

output "cloudfront_distribution_id_full" {
  value = aws_cloudfront_distribution.cf_full.id
}

output "cloudfront_domain_name_activity2" {
  value = aws_cloudfront_distribution.cf_full.domain_name
}

output "website_url" {
  value = "https://${var.domain_name}"
}


# Outputs:

# cloudfront_distribution_id = "E22CFNG272QZ6X"
# cloudfront_distribution_id_full = "E3TLMVUP4557GJ"
# cloudfront_domain_name_activity1 = "d2locdo121k47m.cloudfront.net"
# cloudfront_domain_name_activity2 = "d2mfa69dhubyy3.cloudfront.net"
# s3_bucket_name = "arista-cloudfront"
# website_url = "https://arista-cloudfront.sctp-sandbox.com"
# sus@Vivobook-X409UA:~/cloudfront-tf$