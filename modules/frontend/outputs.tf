output "cloudfront_domain" {
  description = "CloudFront distribution domain name (frontend entry point)."
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (used for invalidations in CI/CD)."
  value       = aws_cloudfront_distribution.frontend.id
}

output "cloudfront_distribution_arn" {
  description = "CloudFront distribution ARN (used by CI/CD invalidation policy)."
  value       = aws_cloudfront_distribution.frontend.arn
}

output "frontend_bucket_id" {
  description = "S3 bucket hosting the SPA static assets."
  value       = aws_s3_bucket.frontend.id
}

output "frontend_bucket_arn" {
  description = "ARN of the frontend S3 bucket (used by CI/CD sync policy)."
  value       = aws_s3_bucket.frontend.arn
}
