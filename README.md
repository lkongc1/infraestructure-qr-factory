# QR Factory — Terraform Infrastructure

Production-grade Terraform (HCL) for **QR Factory**, a serverless QR-code
generation service: a CloudFront-fronted SPA, Cognito auth, a WAF-protected
HTTP API, a Powertools-instrumented Lambda, DynamoDB + private S3 storage,
CloudWatch observability, and a CodePipeline CI/CD.

This repository contains **only the infrastructure code** — Terraform modules,
per-environment roots, the Lambda handler source, and the frontend static
assets. No application backend, no buildspec, no CI config lives here beyond
the Terraform that provisions the pipeline.

## Architecture (5 integrations + frontend)

| Layer | Module | What it does |
|-------|--------|--------------|
| **FE** | `modules/frontend` | SPA on S3 served via CloudFront with Origin Access Control (OAC), TLS 1.2+, security headers, versioning |
| **I1** | `modules/edge` | Cognito (email + MFA, JWT RS256 1h, Hosted UI); WAFv2 (rate limit 100/5min/IP, Bot Control, CoreRuleSet, Anonymous IP list, custom `javascript:` body block, JSON body inspection); HTTP API (`aws_apigatewayv2`) with JWT authorizer + CORS locked to the CloudFront origin |
| **I2** | `modules/lambda` | QR generator Lambda: Python 3.11, arm64, 512MB, 10s timeout, unreserved concurrency, X-Ray tracing, Powertools Logger/Metrics/Tracer. Handler source lives at `src/` |
| **I3** | `modules/data` | Private assets S3 bucket (SSE-S3, block all public access, no lifecycle); DynamoDB on-demand `Templates` (PK=id) and `Quotas` (PK=userId, TTL) with PITR |
| **I4** | `modules/observability` | SNS for PagerDuty; CloudWatch alarms (Latency P99, errors, throttles, quota usage, concurrency, WAF blocked, DDB throttles); "QR-Factory" dashboard with Golden Signals + cost + security panels. Logs/metrics come from the Lambda via EMF |
| **I5** | `modules/cicd` | CodePipeline: Source -> Plan -> Apply -> Frontend; CodeBuild runs Terraform and the frontend S3 sync + CloudFront invalidation |

**Data flow:** `CloudFront -> S3 (SPA)` for the app; `POST /qrs -> WAF -> HTTP API (JWT) -> Lambda` which checks quota (atomic DDB counter), reads template (strong-consistent), renders the QR in RAM, PutObject (SSE-S3, retried) and returns a 1h presigned GET URL. The client downloads the QR directly from S3 via the presigned URL.

## Repository structure

```
infraestructure-qr-factory/
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
├── src/                      # Lambda handler (qr_generator.py + requirements.txt)
├── frontend/                 # SPA static assets (synced to S3 by CI/CD)
├── docker/                   # Local dev container (placeholder)
├── scripts/                  # Helper scripts (placeholder)
├── README.md
└── .gitignore
```

The Terraform root for each environment lives in `environments/<env>/`. There is
no Terraform root at the repository level; the repo root is a container for
modules, environments, source, and CI assets.

## Prerequisites

- Terraform >= 1.5 (CI pins 1.7.0)
- AWS CLI v2 configured with credentials that can create the resources above
- A globally-unique Cognito domain prefix
- (Optional) A Route53 hosted zone + ACM cert for the API custom domain
- (Optional) A CodeStar Connections connection to GitHub for CI/CD
- **For CI/CD:** a `buildspec.yml` at the repository root (see
  [CI/CD & buildspec](#cicd--buildspec) below)

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

> The tracked `environments/<env>/terraform.tfvars` files contain **placeholder
> values only** (`YOURUNIQUE`, `example.com`, empty strings) — no secrets. Fill
> them in locally and never commit real credentials.

## Deploying the Lambda

The Lambda source lives at `src/`. Terraform zips it automatically via the
`archive_file` data source in `modules/lambda`, so a plain `terraform apply`
from `environments/<env>/` packages and deploys the function. The path is wired
through the `source_dir` and `output_path` module variables (set explicitly in
each environment's `main.tf` to `${path.root}/../../src` and
`${path.root}/../../build/qr_generator.zip`, because `path.root` resolves to
the environment dir, not the repo root).

When iterating only on the handler:

```bash
cd src
pip install -r requirements.txt -t ../build/package
# (locally test with something like: python -c "import qr_generator")
cd ../environments/dev
terraform apply -target=module.lambda
```

## CI/CD & buildspec

The `modules/cicd` module provisions a CodePipeline
(`Source -> Plan -> Apply -> Frontend`) and a CodeBuild project. The CodeBuild
project's `source` block references a buildspec **by name**:

```hcl
# modules/cicd/main.tf
source {
  type      = "CODEPIPELINE"
  buildspec = "buildspec.yml"
}
```

This means the pipeline expects a `buildspec.yml` at the **repository root**.
That file is **not included in this repository**; supply it separately (e.g. a
private companion repo, or add it to your fork) before enabling the `cicd`
module. The buildspec drives three phases via a `DEPLOY_PHASE` env var:

- `plan` — `terraform validate` + `terraform plan` (gated validation)
- `apply` — `terraform apply` (infrastructure changes)
- `frontend` — `aws s3 sync` of `frontend/dist` + CloudFront invalidation

If you are not using CI/CD yet, simply comment out the `module "cicd"` block in
`environments/<env>/main.tf` and deploy with local `terraform apply`.

### Canary & rollback (documented)

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
src/                     - QR generator handler (Python) + requirements
frontend/                - SPA static assets (synced to S3 by CI/CD)
docker/                  - Local dev container (placeholder)
scripts/                 - Helper scripts (placeholder)
```

## Notes

- **Backend & state:** each environment bootstraps its own remote state
  (S3 + DynamoDB lock). See `environments/<env>/backend.tf` for the exact
  `aws s3api` / `dynamodb` bootstrap commands and fill in real bucket/lock
  table names before `terraform init`.
- **Paths:** module sources use `../../modules/<name>` relative to the
  environment root, and the Lambda `source_dir`/`output_path` use
  `${path.root}/../../src` and `${path.root}/../../build/...`. Keep the
  `environments/`, `modules/`, and `src/` folders at the repo root for these
  relative paths to resolve.
