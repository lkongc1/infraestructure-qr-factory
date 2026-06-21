variable "name_prefix" {
  description = "Common prefix used by all named resources (e.g. qr-factory-dev)."
  type        = string
}

variable "extra_tags" {
  description = "Extra tags merged on top of the provider default_tags for module resources."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region for all regional resources (frontend is global via CloudFront)."
  type        = string
}

variable "project_name" {
  description = "Project name used in tags and resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (Prod, Staging, Dev). Drives naming and tags."
  type        = string
}

variable "source_provider" {
  description = "Pipeline source provider: github or codecommit."
  type        = string
}

variable "github_repo_owner" {
  description = "GitHub repository owner (org or user). Used when source_provider = github."
  type        = string
}

variable "github_repo_name" {
  description = "GitHub repository name. Used when source_provider = github."
  type        = string
}

variable "github_branch" {
  description = "Source branch tracked by the pipeline."
  type        = string
}

variable "github_connection_arn" {
  description = "ARN of the CodeStar Connections connection to GitHub. Required when source_provider = github."
  type        = string
}

variable "codecommit_repo_name" {
  description = "CodeCommit repository name. Used when source_provider = codecommit."
  type        = string
}

variable "frontend_bucket_arn" {
  description = "ARN of the frontend S3 bucket (from the frontend module). Used by the codebuild_terraform policy FrontendSyncAndInvalidate statement."
  type        = string
}

variable "cloudfront_distribution_arn" {
  description = "ARN of the CloudFront distribution (from the frontend module). Used by the codebuild_terraform policy CloudFrontInvalidation statement."
  type        = string
}

variable "account_id" {
  description = "AWS account ID (from the root data.aws_caller_identity.current). Used to scope iam:PassRole and the CodeCommit repository ARN."
  type        = string
}

variable "artifacts_bucket_name" {
  description = "Globally-unique name for the CI/CD artifacts S3 bucket (precomputed in root locals, single source of truth)."
  type        = string
}

variable "pipeline_name" {
  description = "CodePipeline name (precomputed in root locals, single source of truth)."
  type        = string
}

variable "codebuild_name" {
  description = "CodeBuild project name (precomputed in root locals, single source of truth)."
  type        = string
}
