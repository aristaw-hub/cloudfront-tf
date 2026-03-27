#activity 1
# main.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"  # Singapore region
}

# Variables
variable "bucket_name" {
  description = "Name of the S3 bucket"
  type        = string
  default     = "arista-cf-bucket-terraform"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

# 1. Create S3 bucket (private, no public access)
resource "aws_s3_bucket" "static_site" {
  bucket = var.bucket_name
  
  tags = {
    Name        = var.bucket_name
    Environment = var.environment
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enable versioning for backups
resource "aws_s3_bucket_versioning" "static_site" {
  bucket = aws_s3_bucket.static_site.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 2. Upload static site files (using aws_s3_object)
resource "aws_s3_object" "website_files" {
  for_each = fileset("${path.module}/static-website", "**/*")
  
  bucket       = aws_s3_bucket.static_site.id
  key          = each.value
  source       = "${path.module}/static-website/${each.value}"
  etag         = filemd5("${path.module}/static-website/${each.value}")
  content_type = lookup({
    "html" = "text/html"
    "css"  = "text/css"
    "js"   = "application/javascript"
    "png"  = "image/png"
    "jpg"  = "image/jpeg"
    "jpeg" = "image/jpeg"
    "gif"  = "image/gif"
    "svg"  = "image/svg+xml"
  }, element(split(".", each.value), length(split(".", each.value)) - 1), "application/octet-stream")
}

# 3. Create CloudFront Origin Access Control (OAC)
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.bucket_name}-oac"
  description                       = "OAC for ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 4. Create CloudFront distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  
  # Origin configuration
  origin {
    domain_name              = aws_s3_bucket.static_site.bucket_regional_domain_name
    origin_id                = "S3-${var.bucket_name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }
  
  # Default cache behavior
  default_cache_behavior {
    target_origin_id       = "S3-${var.bucket_name}"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    
    # Lambda@Edge for response headers (optional)
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.add_security_headers.arn
    }
  }
  
  # Price class - use all edge locations for best performance
  price_class = "PriceClass_All"
  
  # Restrictions - no geo restriction
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  
  # SSL certificate - default CloudFront certificate
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }
  
  # Custom error responses
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
  
  tags = {
    Name        = "${var.bucket_name}-distribution"
    Environment = var.environment
  }
}

# Optional: CloudFront function to add security headers
resource "aws_cloudfront_function" "add_security_headers" {
  name    = "add-security-headers"
  runtime = "cloudfront-js-2.0"
  comment = "Add security headers to responses"
  publish = true
  
  code = <<-EOF
    function handler(event) {
      var response = event.response;
      var headers = response.headers;
      
      headers['strict-transport-security'] = { value: 'max-age=63072000; includeSubdomains; preload' };
      headers['x-content-type-options'] = { value: 'nosniff' };
      headers['x-frame-options'] = { value: 'DENY' };
      headers['x-xss-protection'] = { value: '1; mode=block' };
      headers['referrer-policy'] = { value: 'strict-origin-when-cross-origin' };
      
      return response;
    }
  EOF
}

# 5. S3 bucket policy allowing CloudFront access
resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.static_site.id
  policy = data.aws_iam_policy_document.allow_cloudfront_access.json
}

data "aws_iam_policy_document" "allow_cloudfront_access" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static_site.arn}/*"]
    
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
    }
  }
}

# Outputs
output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.s3_distribution.domain_name
  description = "CloudFront distribution domain name"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.static_site.id
  description = "S3 bucket name"
}