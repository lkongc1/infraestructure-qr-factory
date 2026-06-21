###############################################################################
# I3 - DATA
# Private assets S3 bucket (SSE-S3, no lifecycle, block all public access) and
# two DynamoDB on-demand tables (Templates, Quotas with TTL).
###############################################################################

# --- Assets bucket ----------------------------------------------------------

resource "aws_s3_bucket" "assets" {
  bucket = var.assets_bucket_name

  tags = merge(var.extra_tags, {
    Name  = var.assets_bucket_name
    Layer = "I3-Data"
  })
}

# Block ALL public access. Assets are only ever served via presigned URLs.
resource "aws_s3_bucket_public_access_block" "assets" {
  bucket = aws_s3_bucket.assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE-S3 (Amazon S3 managed keys). Architecture explicitly requires SSE-S3,
# NOT SSE-KMS, to keep presigned URL generation simple and key-policy-free.
resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning off for assets (they are immutable per qrId); no lifecycle, no
# Glacier transition per architecture.
resource "aws_s3_bucket_ownership_controls" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# --- DynamoDB: Templates ----------------------------------------------------

resource "aws_dynamodb_table" "templates" {
  name         = var.templates_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.extra_tags, {
    Name  = var.templates_table_name
    Layer = "I3-Data"
    Kind  = "Templates"
  })
}

# --- DynamoDB: Quotas (with TTL) -------------------------------------------

resource "aws_dynamodb_table" "quotas" {
  name         = var.quotas_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"

  attribute {
    name = "userId"
    type = "S"
  }

  # TTL lets per-day quota counters auto-expire at end of day (UTC).
  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.extra_tags, {
    Name  = var.quotas_table_name
    Layer = "I3-Data"
    Kind  = "Quotas"
  })
}
