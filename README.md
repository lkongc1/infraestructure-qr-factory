# QR Factory - Terraform Infrastructure

Production Terraform (HCL) for the QR Factory application: a serverless QR-code
generation service with a CloudFront-fronted SPA, Cognito auth, a WAF-protected
HTTP API, a Powertools-instrumented Lambda, DynamoDB + private S3 storage,
CloudWatch observability, and a CodePipeline CI/CD.

## Architecture (5 integrations + frontend)

| Layer | Module | What it does |
|-------|--------|--------------|
| **FE**  | `modules/frontend` | SPA on S3 served via CloudFront with Origin Access Control (OAC), TLS 1.2+, security headers, versioning |
| **I1**  | `modules/edge` | Cognito (email + MFA, JWT RS256 1h, Hosted UI); WAFv2 (rate limit 100/5min/IP, Bot Control, CoreRuleSet, Anonymous IP list, custom `javascript:` body block, JSON body inspection); HTTP API (`aws_apigatewayv2`) with JWT authorizer + CORS locked to the CloudFront origin |
| **I2** | `modules/lambda` | QR generator Lambda: Node.js 20.x (ESM), arm64, 512MB, 10s timeout, unreserved concurrency, X-Ray tracing, Powertools Logger/Metrics/Tracer (TypeScript). Handler source lives at `src/index.mjs` |
| **I3**  | `modules/data` | Private assets S3 bucket (SSE-S3, block all public access, no lifecycle); DynamoDB on-demand `Templates` (PK=id) and `Quotas` (PK=userId, TTL) with PITR |
| **I4**  | `modules/observability` | SNS for PagerDuty; CloudWatch alarms (Latency P99, errors, throttles, quota usage, concurrency, WAF blocked, DDB throttles); "QR-Factory" dashboard with Golden Signals + cost + security panels. Logs/metrics come from the Lambda via EMF |
| **I5**  | `modules/cicd` + `buildspec.yml` | CodePipeline: Source -> Plan -> Apply -> Frontend; CodeBuild runs Terraform and the frontend S3 sync + CloudFront invalidation |

Data flow: `CloudFront -> S3 (SPA)` for the app; `POST /qrs -> WAF -> HTTP API (JWT) -> Lambda` which checks quota (atomic DDB counter), reads template (strong-consistent), renders the QR in RAM, PutObject (SSE-S3, retried) and returns a 1h presigned GET URL. The client downloads the QR directly from S3 via the presigned URL.

## Prerequisites

- Terraform >= 1.5
- AWS CLI v2 configured with credentials that can create the resources above
- A globally-unique Cognito domain prefix
- (Optional) A Route53 hosted zone + ACM cert for the API custom domain
- (Optional) A CodeStar Connections connection to GitHub for CI/CD

## Structure

```
qr-factory-infra/
├── modules/                  # Reusable child modules (no provider/backend)
│   ├── data/                 # I3: S3 assets + DynamoDB Templates/Quotas
│   ├── frontend/             # FE: S3 + CloudFront (OAC, security headers)
│   ├── lambda/               # I2: QR generator function + role + archive_file
│   ├── edge/                 # I1: Cognito + WAF + HTTP API
│   ├── observability/        # I4: SNS + alarms + dashboard
│   └── cicd/                 # I5: CodePipeline + CodeBuild + roles
├── environments/             # Per-env Terraform roots (provider + backend live here)
│   ├── dev/                  # Dev: local CORS, PriceClass_100, 7d logs, 20 quota
│   └── prod/                 # Prod: custom API domain, PriceClass_All, 30d logs
├── src/                      # Lambda handler (index.mjs + package.json, Node 20 ESM)
├── frontend/                 # SPA static assets (synced to S3 by CI/CD)
├── docker/                   # Local dev container (placeholder)
├── scripts/                  # Helper scripts (placeholder)
├── buildspec.yml             # CodeBuild: terraform plan/apply + frontend deploy
├── README.md
└── .gitignore
```

The Terraform root for each environment lives in `environments/<env>/`. There is
no Terraform root at the `qr-factory-infra/` level anymore; the project root is
a container for modules, environments, source, and CI.

## Commands (per environment)

```bash
# 1. (One-time) bootstrap the remote state backend - see
#    environments/<env>/backend.tf for the exact s3api/dynamodb commands,
#    then fill in the real bucket/lock-table names.

cd environments/dev           # or environments/prod
terraform init
terraform plan                # reads terraform.tfvars automatically
terraform apply

# Override a value ad-hoc without editing tfvars:
terraform plan -var "cognito_domain_prefix=my-qr-factory-dev"
```

Variables are documented in `environments/<env>/variables.tf`. Pass sensitive
ones (e.g. `pagerduty_sns_endpoint`, `github_connection_arn`) via environment
variables (`TF_VAR_pagerduty_sns_endpoint=...`) rather than editing tfvars.

## Deploying the Lambda

The Lambda source lives at `src/` (`index.mjs` + `package.json`). Terraform
zips the whole `src/` directory via the `archive_file` data source in
`modules/lambda`, so a plain `terraform apply` from `environments/<env>/`
packages and deploys the function. The path is wired through the `source_dir`
and `output_path` module variables (set explicitly in each environment's
`main.tf` to `${path.root}/../../src` and
`${path.root}/../../build/qr_generator.zip`, because `path.root` resolves to
the environment dir, not the repo root).

**Before the first apply** (and after any dependency change), install the
Node dependencies into `src/` so they are included in the zip:

```bash
cd src
npm install --production
cd ../environments/dev
terraform apply
```

When iterating only on the handler (no dependency changes):

```bash
cd environments/dev
terraform apply -target=module.lambda
```

To syntax-check the handler locally without deploying:

```bash
cd src
node --check index.mjs
```

## CI/CD canary & rollback (documented)

Terraform has no native canary; this project reduces blast radius by:

- **Infra**: gating `terraform plan` as a pipeline stage and keeping remote
  state versioned in S3. Rollback = re-run the pipeline against the previous
  commit; `terraform apply` converges state back.
- **Frontend**: S3 versioning is enabled. A deploy writes a new object version;
  rollback = `aws s3api copy-object` of the prior `versionId` + a CloudFront
  invalidation. A canary can be staged via a separate key prefix and a
  progressively shifted CloudFront origin path.
- **Alarms**: SNS feeds PagerDuty; wire a manual approval stage or an
  auto-rollback job that re-applies the last known-good commit on alarm.

## File map

```
modules/data/            - I3: assets S3 bucket + Templates/Quotas DynamoDB tables
modules/frontend/        - FE: S3 + CloudFront (OAC, security headers)
modules/lambda/          - I2: Lambda function + role + archive_file + policies
modules/edge/            - I1: Cognito + WAFv2 + HTTP API v2
modules/observability/   - I4: SNS + CloudWatch alarms + dashboard
modules/cicd/            - I5: CodePipeline + CodeBuild + roles
environments/dev/        - Dev Terraform root (provider, backend, locals, vars, tfvars, main, outputs)
environments/prod/       - Prod Terraform root (provider, backend, locals, vars, tfvars, main, outputs)
src/                     - QR generator handler (Node.js 20 ESM) + package.json
buildspec.yml            - CodeBuild: terraform plan/apply + frontend deploy
frontend/                - SPA static assets (synced to S3 by CI/CD)
docker/                  - Local dev container (placeholder)
scripts/                 - Helper scripts (placeholder)
```
