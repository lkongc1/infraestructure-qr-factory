variable "name_prefix" {
  description = "Common prefix used by all named resources (e.g. qr-factory-dev)."
  type        = string
}

variable "frontend_bucket_name" {
  description = "Globally-unique name for the frontend S3 bucket hosting the SPA."
  type        = string
}

variable "extra_tags" {
  description = "Extra tags merged on top of the provider default_tags for module resources."
  type        = map(string)
  default     = {}
}

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 = US/EU only; PriceClass_All = global."
  type        = string
}

variable "cognito_auth_domain" {
  description = "Pre-built Cognito Hosted UI domain (https://<prefix>.auth.<region>.amazoncognito.com) used in the CSP connect-src directive. Single source of truth: derived once in the root locals and passed in."
  type        = string
}
