output "lambda_function_name" {
  description = "QR generator Lambda function name."
  value       = aws_lambda_function.qr_generator.function_name
}

output "lambda_arn" {
  description = "QR generator Lambda ARN."
  value       = aws_lambda_function.qr_generator.arn
}

output "lambda_invoke_arn" {
  description = "QR generator Lambda invoke ARN (used by the HTTP API integration)."
  value       = aws_lambda_function.qr_generator.invoke_arn
}
