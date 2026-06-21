output "pipeline_arn" {
  description = "CodePipeline ARN."
  value       = aws_codepipeline.main.arn
}
