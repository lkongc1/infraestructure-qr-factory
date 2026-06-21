output "assets_bucket_id" {
  description = "Private S3 bucket storing generated QR PNGs (presigned URL access)."
  value       = aws_s3_bucket.assets.id
}

output "assets_bucket_arn" {
  description = "ARN of the private assets S3 bucket."
  value       = aws_s3_bucket.assets.arn
}

output "templates_table_name" {
  description = "DynamoDB Templates table name."
  value       = aws_dynamodb_table.templates.name
}

output "templates_table_arn" {
  description = "ARN of the DynamoDB Templates table."
  value       = aws_dynamodb_table.templates.arn
}

output "quotas_table_name" {
  description = "DynamoDB Quotas table name (PK=userId, TTL enabled)."
  value       = aws_dynamodb_table.quotas.name
}

output "quotas_table_arn" {
  description = "ARN of the DynamoDB Quotas table."
  value       = aws_dynamodb_table.quotas.arn
}
