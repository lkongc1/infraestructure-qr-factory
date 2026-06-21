# frontend/

Source for the QR Factory SPA (React, Vue, or equivalent) that is deployed to
the S3 bucket + CloudFront distribution provisioned by
`../modules/frontend/`. The Terraform infrastructure for hosting the SPA
exists today (S3 website configuration, CloudFront OAC, security headers,
versioning for rollback); the SPA application code does not exist yet.

When the SPA is added, build it to a `dist/` directory and deploy it via the
`frontend` phase of the CI/CD pipeline (see `../buildspec.yml`), which runs
`aws s3 sync` against the frontend bucket and issues a CloudFront invalidation.
