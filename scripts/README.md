# scripts/

Operational scripts for the QR Factory infrastructure: deploy helpers, rollback
helpers, and one-off bootstrap utilities (for example, seeding the remote state
backend bucket + DynamoDB lock table, or running a targeted frontend rollback
via `aws s3api copy-object` of a prior object version followed by a CloudFront
invalidation).

This directory is a placeholder; no scripts are shipped yet. Add executable
helpers here as operational needs arise.
