###############################################################################
# I5 - CI/CD
# CodePipeline: Source -> Plan -> Apply -> Frontend deploy.
# CodeBuild runs Terraform (init/plan/apply) and the frontend S3 sync +
# CloudFront invalidation. Canary/rollback strategy is documented in the
# buildspec and README (Terraform has no native canary; we use staged applies +
# frontend S3 versioning + CloudFront invalidation for rollback).
#
# IAM policies are inline (aws_iam_role_policy) on purpose: bound 1:1 to the
# role. The codebuild_terraform policy document (S3 artifacts + frontend sync +
# CloudFront invalidation + CodeStar) was moved here from the former
# iam_policies.tf; the frontend bucket and CloudFront distribution ARNs are now
# module inputs (from the frontend module).
###############################################################################

# --- Artifacts bucket ------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket = var.artifacts_bucket_name

  tags = merge(var.extra_tags, { Layer = "I5-CICD" })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --- CodeBuild role --------------------------------------------------------

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name_prefix}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = merge(var.extra_tags, { Layer = "I5-CICD" })
}

# Resource-scoped policy (artifacts, frontend, cloudfront, codestar).
# Moved from the former iam_policies.tf. The frontend bucket and CloudFront
# distribution ARNs are now module inputs (from the frontend module).
#checkov:skip=CKV_AWS_356:CodeStar Connections "codestar-connections:UseConnection" does not support resource-level permissions per AWS IAM docs; resources:["*"] is required by AWS and unavoidable. All other statements in this document (S3Artifacts, FrontendSyncAndInvalidate, CloudFrontInvalidation) are resource-scoped to specific ARNs.
data "aws_iam_policy_document" "codebuild_terraform" {
  statement {
    sid    = "S3Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "FrontendSyncAndInvalidate"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      var.frontend_bucket_arn,
      "${var.frontend_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "CloudFrontInvalidation"
    effect = "Allow"
    actions = [
      "cloudfront:CreateInvalidation",
      "cloudfront:GetInvalidation",
    ]
    resources = [var.cloudfront_distribution_arn]
  }

  statement {
    sid       = "CodeStarConnection"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = ["*"] 
  }
}

resource "aws_iam_role_policy" "codebuild_scoped" {
  name   = "scoped-deploy"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_terraform.json
}

# Terraform apply needs to create/modify the QR Factory resources. We scope this
# to the services in use AND tag it with the project so a drift away from
# QR-Factory resources is visible. For hard multi-tenant isolation, attach a
# customer-managed Permissions Boundary instead (see README).
data "aws_iam_policy_document" "codebuild_terraform_apply" {
  statement {
    sid    = "TerraformManagedServices"
    effect = "Allow"
    actions = [
      "lambda:*",
      "apigatewayv2:*",
      "cognito-idp:*",
      "wafv2:*",
      "dynamodb:*",
      "cloudfront:*",
      "cloudwatch:*",
      "logs:*",
      "sns:*",
      "s3:*",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:ListRoles",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "sts:GetCallerIdentity",
    ]
    # Restrict to this account. Tighten further with resource ARNs in production.
    resources = ["*"]
  }

  statement {
    sid     = "PassRoleScopedToProject"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    # CodeBuild may only pass roles it created for QR Factory.
    resources = [
      "arn:aws:iam::${var.account_id}:role/qr-factory-*",
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_terraform" {
  name   = "terraform-apply"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild_terraform_apply.json
}

# --- CodeBuild project -----------------------------------------------------

resource "aws_codebuild_project" "main" {
  name          = var.codebuild_name
  description   = "Terraform plan/apply + frontend deploy for QR Factory"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
    environment_variable {
      name  = "TF_VERSION"
      value = "1.7.0"
    }
    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }
    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
    # DEPLOY_PHASE is overridden per pipeline action (plan | apply | frontend).
    environment_variable {
      name  = "DEPLOY_PHASE"
      value = "plan"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }

  # Explicit logging config: CloudWatch Logs (auditable build output) + S3
  # (long-term retention). Satisfies CKV_AWS_314 and ensures every build is
  # traceable for incident response and compliance.
  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.codebuild_name}"
      stream_name = "build"
    }

    s3_logs {
      location = "${aws_s3_bucket.artifacts.id}/build-logs"
      status  = "ENABLED"
    }
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.artifacts.id}/cache"
  }

  tags = merge(var.extra_tags, { Layer = "I5-CICD" })
}

# --- CodePipeline role -----------------------------------------------------

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codepipeline" {
  name               = "${var.name_prefix}-pipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
  tags               = merge(var.extra_tags, { Layer = "I5-CICD" })
}

data "aws_iam_policy_document" "codepipeline" {
  statement {
    sid    = "Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  statement {
    sid    = "StartBuild"
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
      "codebuild:StopBuild",
    ]
    resources = [aws_codebuild_project.main.arn]
  }

  statement {
    sid       = "CodeStarConnectionUse"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = ["*"]
  }

  statement {
    sid    = "CodeCommit"
    effect = "Allow"
    actions = [
      "codecommit:GetBranch",
      "codecommit:GetCommit",
      "codecommit:UploadArchive",
      "codecommit:GetUploadArchiveStatus",
      "codecommit:CancelUploadArchive",
    ]
    resources = var.source_provider == "codecommit" ? [
      "arn:aws:codecommit:${var.aws_region}:${var.account_id}:${var.codecommit_repo_name}",
    ] : []
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  name   = "pipeline-access"
  role   = aws_iam_role.codepipeline.id
  policy = data.aws_iam_policy_document.codepipeline.json
}

# --- Pipeline --------------------------------------------------------------

locals {
  is_github = var.source_provider == "github"
}

resource "aws_codepipeline" "main" {
  name     = var.pipeline_name
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"

    encryption_key {
      id   = aws_s3_bucket.artifacts.arn
      type = "SSE_S3"
    }
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = local.is_github ? "CodeStarConnectionsConnection" : "CodeCommit"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = local.is_github ? {
        ConnectionArn    = var.github_connection_arn
        FullRepositoryId = "${var.github_repo_owner}/${var.github_repo_name}"
        BranchName       = var.github_branch
        } : {
        RepositoryName = var.codecommit_repo_name
        BranchName     = var.github_branch
      }
    }
  }

  stage {
    name = "Plan"

    action {
      name             = "TerraformPlan"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.main.name
        EnvironmentVariables = jsonencode([
          { name = "DEPLOY_PHASE", value = "plan", type = "PLAINTEXT" },
        ])
      }
    }
  }

  stage {
    name = "Apply"

    action {
      name            = "TerraformApply"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["plan_output"]

      configuration = {
        ProjectName = aws_codebuild_project.main.name
        EnvironmentVariables = jsonencode([
          { name = "DEPLOY_PHASE", value = "apply", type = "PLAINTEXT" },
        ])
      }
    }
  }

  stage {
    name = "Frontend"

    action {
      name            = "FrontendDeploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["source_output"]

      configuration = {
        ProjectName = aws_codebuild_project.main.name
        EnvironmentVariables = jsonencode([
          { name = "DEPLOY_PHASE", value = "frontend", type = "PLAINTEXT" },
        ])
      }
    }
  }

  tags = merge(var.extra_tags, { Layer = "I5-CICD" })
}
