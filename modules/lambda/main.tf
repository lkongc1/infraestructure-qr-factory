###############################################################################
# I2 - COMPUTE
# QR generator Lambda: Python 3.11, arm64, 512MB, 10s timeout (fail-fast),
# unreserved concurrency (reserved_concurrent_executions intentionally unset),
# X-Ray active tracing, Powertools Logger/Metrics/Tracer.
#
# IAM policies are inline (aws_iam_role_policy) on purpose: the policy is bound
# 1:1 to the role and cannot be reused/over-granted. The DynamoDB and S3 policy
# documents were moved here from the former iam_policies.tf; their resource ARNs
# are now module inputs (from the data module).
###############################################################################

# --- Package the handler from src/ (Option B: project-root src/) -----------

data "archive_file" "qr_generator" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = var.output_path
}

# --- Log group (30d retention) ---------------------------------------------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = var.lambda_log_group
  retention_in_days = var.log_retention_days

  tags = merge(var.extra_tags, {
    Layer = "I2-Compute"
    Kind  = "LambdaLogs"
  })
}

# --- Execution role --------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = merge(var.extra_tags, { Layer = "I2-Compute" })
}

# Inline least-privilege policies bound 1:1 to the role.
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "dynamodb-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}

resource "aws_iam_role_policy" "lambda_s3" {
  name   = "s3-assets-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_s3.json
}

resource "aws_iam_role_policy" "lambda_logging_tracing" {
  name   = "logging-tracing"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_logging_tracing.json
}

# --- Lambda function -------------------------------------------------------

resource "aws_lambda_function" "qr_generator" {
  function_name = var.lambda_function_name
  description   = "Generates QR codes from validated URLs. Powertools-instrumented."

  filename         = data.archive_file.qr_generator.output_path
  source_code_hash = data.archive_file.qr_generator.output_base64sha256

  role    = aws_iam_role.lambda.arn
  handler = "qr_generator.handler"
  runtime = "python3.11"

  # Architecture + sizing per architecture spec.
  architectures = ["arm64"]
  memory_size   = var.lambda_memory_size
  timeout       = var.lambda_timeout_seconds

  # Unreserved concurrency = do NOT set reserved_concurrent_executions.
  # The function draws from the account-wide unreserved pool.

  # Active X-Ray tracing so the Tracer in Powertools has segments to write.
  tracing_config {
    mode = "Active"
  }

  # Powertools config via env. EMF namespace drives CloudWatch metrics.
  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "qr-factory"
      POWERTOOLS_METRICS_NAMESPACE = "QRFactory"
      POWERTOOLS_LOG_LEVEL         = "INFO"
      LOG_LEVEL                    = "INFO"
      ASSETS_BUCKET                = var.assets_bucket_id
      TEMPLATES_TABLE              = var.templates_table_name
      QUOTAS_TABLE                 = var.quotas_table_name
      QUOTA_LIMIT_PER_USER         = tostring(var.quota_limit_per_user)
      PRESIGNED_URL_EXPIRY_SECONDS = "3600"
      AWS_XRAY_TRACING_NAME        = "qr-factory"
    }
  }

  # Ensure the log group exists before the function so CloudWatch retains it.
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda_logging_tracing,
  ]

  tags = merge(var.extra_tags, {
    Layer = "I2-Compute"
    Kind  = "QRGenerator"
  })
}

# --- Lambda: DynamoDB access (Templates + Quotas only) ---------------------
# Moved from the former iam_policies.tf. Resource ARNs are now module inputs.

data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    sid    = "TemplatesReadWrite"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:BatchGetItem",
    ]
    resources = [
      var.templates_table_arn,
      "${var.templates_table_arn}/index/*",
    ]
  }

  statement {
    sid    = "QuotasAtomicCounter"
    effect = "Allow"
    # update_item with ADD expression implements the atomic counter.
    # ConditionExpression enforces the quota ceiling inside the Lambda code.
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
    ]
    resources = [var.quotas_table_arn]
  }
}

# --- Lambda: S3 assets access (specific bucket only) -----------------------

data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid    = "AssetsPutAndGet"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${var.assets_bucket_arn}/*"]
  }

  statement {
    sid       = "AssetsListPrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.assets_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["qrs/*"]
    }
  }
}

# --- Lambda: logging + tracing base ----------------------------------------

data "aws_iam_policy_document" "lambda_logging_tracing" {
  statement {
    sid    = "CreateLogStream"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.lambda.arn}:*",
    ]
  }

  statement {
    sid    = "XRayEmit"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"] # X-Ray requires wildcard; this is an AWS-acknowledged exception.
  }
}
