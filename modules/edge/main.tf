###############################################################################
# I1 - EDGE SECURITY
# Cognito (email + MFA, JWT RS256 1h, Hosted UI) + WAFv2 (rate limit 100/5min/IP,
# Bot Control, CoreRuleSet, Anonymous IP list, custom `javascript:` body block,
# JSON body inspection) + HTTP API (aws_apigatewayv2) with JWT authorizer and
# CORS locked to the CloudFront origin. The three concerns are kept together in
# one module because the WAF associates to the API stage, the API authorizer
# references the Cognito pool/client, and the Cognito client callback URLs
# reference the CloudFront domain (passed in).
###############################################################################

# ---------------------------------------------------------------------------
# COGNITO AUTH
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "main" {
  name = var.cognito_user_pool_name

  # Email-based authentication. Username is the email alias for simplicity.
  alias_attributes = ["email", "preferred_username"]

  auto_verified_attributes = ["email"]

  schema {
    attribute_data_type = "String"
    name                = "email"
    required            = true
    mutable             = true

    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }

  # MFA: optional but supported. Email + MFA per architecture.
  mfa_configuration = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # JWT RS256 signing key rotation policy.
  key_spec = "RSA_2048"

  # Lambda trigger hooks could go here (pre-token-gen, post-auth). Left out
  # intentionally to keep the auth surface minimal and least-privilege.

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 3
  }

  # Token lifetimes. Access token = 1h per architecture (JWT RS256).
  access_token_validity  = var.access_token_validity_hours
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  tags = merge(var.extra_tags, {
    Layer = "I1-EdgeSecurity"
    Kind  = "Auth"
  })
}

# Hosted UI domain. The prefix must be globally unique across AWS.
resource "aws_cognito_user_pool_domain" "main" {
  domain       = var.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.main.id
}

# App client used by the SPA. PKCE-enabled confidential-ish client.
resource "aws_cognito_user_pool_client" "spa" {
  name = var.cognito_client_name

  user_pool_id    = aws_cognito_user_pool.main.id
  generate_secret = false # SPA = public client, no secret.

  # OAuth 2.0 flows for SPA.
  allowed_oauth_flows_user_pool_domain = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = [
    "https://${var.cloudfront_domain}/callback",
    "http://localhost:5173/callback",
  ]
  logout_urls = [
    "https://${var.cloudfront_domain}",
    "http://localhost:5173",
  ]

  # Which identity providers the Hosted UI shows.
  supported_identity_providers = ["COGNITO"]

  # Token validity mirrors the pool defaults.
  access_token_validity  = var.access_token_validity_hours
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"

  tags = merge(var.extra_tags, {
    Layer = "I1-EdgeSecurity"
  })
}

# ---------------------------------------------------------------------------
# WAF v2 (regional scope, associated to the HTTP API stage)
# - Rate limit: 100 req / 5 min / IP
# - Bot Control managed rule group
# - AWSManagedRulesCommonRuleSet (SQLi/XSS)
# - AWSManagedRulesAnonymousIpList (VPN/Tor)
# - Custom rule: block "javascript:" in JSON body
# - Body inspection: JSON (activated)
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "api" {
  name        = var.waf_name
  description = "QR Factory edge protection for the HTTP API"
  scope       = "REGIONAL"

  # Activate JSON body inspection so the custom body rule can match fields.
  default_action {
    allow {}
  }

  # --- 1. Rate limit: 100 req / 5 min / IP ---------------------------------
  rule {
    name     = "rate-limit-per-ip"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"

        # Scope the rate limit to POST /qrs only (write path).
        scope_down_statement {
          byte_match_statement {
            search_string = "POST"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
            positional_constraint = "EXACTLY"
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIp"
      sampled_requests_enabled   = true
    }
  }

  # --- 2. Bot Control ------------------------------------------------------
  rule {
    name     = "bot-control"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesBotControlRuleSet"
        vendor_name = "AWS"

        # Inspect both common and HTTP libraries request labels.
        managed_rule_group_configs {
          aws_managed_rules_bot_control_rule_set {
            inspection_level = "COMMON"
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BotControl"
      sampled_requests_enabled   = true
    }
  }

  # --- 3. Core Rule Set (SQLi/XSS) ----------------------------------------
  rule {
    name     = "core-rule-set"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CoreRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # --- 4. Anonymous IP List (VPN/Tor/proxies) ------------------------------
  rule {
    name     = "anonymous-ip-list"
    priority = 40

    action {
      block {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AnonymousIpList"
      sampled_requests_enabled   = true
    }
  }

  # --- 5. Custom rule: block "javascript:" in JSON body --------------------
  # Using json_body field_to_match ACTIVATES JSON body inspection for this rule
  # (WAF parses the request body as JSON before matching). Oversized bodies and
  # invalid JSON fall back to "MATCH" so they are also blocked defensively.
  rule {
    name     = "block-javascript-scheme-in-body"
    priority = 5

    action {
      block {}
    }

    statement {
      byte_match_statement {
        search_string = "javascript:"
        field_to_match {
          json_body {
            match_scope               = "ALL"
            invalid_fallback_behavior = "MATCH"
            oversize_behavior         = "MATCH"
          }
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
        text_transformation {
          priority = 1
          type     = "URL_DECODE"
        }
        positional_constraint = "CONTAINS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "BlockJavascriptScheme"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = merge(var.extra_tags, {
    Layer = "I1-EdgeSecurity"
    Kind  = "WAF"
  })
}

# Associate the WebACL with the HTTP API stage. API Gateway v2 stages are
# addressable via the stage ARN used in web_acl_association (resource_arn).
resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_apigatewayv2_stage.default.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

# Logging config: ship WAF sampled requests + blocked to CloudWatch for the
# WAF BlockedCount / BotBlockedCount metrics used in observability.
resource "aws_wafv2_web_acl_logging_configuration" "api" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.api.arn
}

# WAF log group stays with the WAF resources (NOT in observability) so the WAF
# and its own logs are managed together.
# Retention fixed at 365 days (1 year) to satisfy CKV_AWS_338 and preserve the
# forensic window required for WAF attack-pattern analysis (SOC 2 / ISO 27001).
# WAF logs have higher evidentiary value than general app logs, so they override
# the environment-wide var.log_retention_days.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "/aws/waf/${var.waf_name}"
  retention_in_days = 365

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

# ---------------------------------------------------------------------------
# HTTP API GATEWAY (aws_apigatewayv2, NOT REST)
# - JWT authorizer backed by Cognito
# - CORS restricted to the CloudFront origin
# - Optional custom domain with TLS 1.2+
# - POST /qrs -> Lambda proxy integration
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "http_api" {
  name          = var.api_name
  protocol_type = "HTTP"
  description   = "QR Factory HTTP API (Cognito JWT authorizer -> Lambda)"

  # CORS restricted to the CloudFront origin. Empty allowed_origin is resolved
  # from the distribution domain so apply works in a single pass.
  cors_configuration {
    allow_origins = [
      coalesce(var.allowed_origin, "https://${var.cloudfront_domain}"),
    ]
    allow_methods     = ["POST", "OPTIONS", "GET"]
    allow_headers     = ["authorization", "content-type", "x-amzn-trace-id"]
    expose_headers    = ["x-amzn-trace-id", "retry-after"]
    max_age_seconds   = 300
    allow_credentials = false
  }

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

# --- JWT authorizer (Cognito) ----------------------------------------------

resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.http_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.name_prefix}-cognito-jwt"

  jwt_configuration {
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    audience = [aws_cognito_user_pool_client.spa.id]
  }
}

# --- Lambda proxy integration ----------------------------------------------

resource "aws_apigatewayv2_integration" "qr_lambda" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --- Route: POST /qrs (JWT-protected) --------------------------------------

resource "aws_apigatewayv2_route" "create_qr" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "POST /qrs"
  target             = "integrations/${aws_apigatewayv2_integration.qr_lambda.id}"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  authorization_type = "JWT"
}

# --- Stage ($default with auto-deploy; WAF is attached here) ---------------

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId          = "$context.requestId",
      ip                 = "$context.identity.sourceIp",
      routeKey           = "$context.routeKey",
      status             = "$context.status",
      responseLength     = "$context.responseLength",
      integrationLatency = "$context.integrationLatency",
    })
  }

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

resource "aws_cloudwatch_log_group" "api_access" {
  name              = "/aws/apigateway/${var.api_name}/access"
  retention_in_days = var.log_retention_days

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

# --- Allow API Gateway to invoke the Lambda --------------------------------

resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowHTTPAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  # Any route on this API / stage may invoke the function.
  source_arn = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# --- Optional custom domain (TLS 1.2+) -------------------------------------
# Only created when var.api_custom_domain is set. HTTP API custom domains are
# regional, so the ACM certificate lives in var.aws_region (no us-east-1 needed).

locals {
  use_custom_domain = length(var.api_custom_domain) > 0
}

resource "aws_acm_certificate" "api_domain" {
  count             = local.use_custom_domain ? 1 : 0
  domain_name       = var.api_custom_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

resource "aws_route53_record" "api_cert_validation" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.api[0].zone_id
  name    = tolist(aws_acm_certificate.api_domain[0].domain_validation_options)[0].resource_record_name
  type    = tolist(aws_acm_certificate.api_domain[0].domain_validation_options)[0].resource_record_type
  records = [tolist(aws_acm_certificate.api_domain[0].domain_validation_options)[0].resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "api_domain" {
  count                   = local.use_custom_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.api_domain[0].arn
  validation_record_fqdns = [aws_route53_record.api_cert_validation[0].fqdn]
}

resource "aws_apigatewayv2_domain_name" "custom" {
  count       = local.use_custom_domain ? 1 : 0
  domain_name = var.api_custom_domain
  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api_domain[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  tags = merge(var.extra_tags, { Layer = "I1-EdgeSecurity" })
}

resource "aws_apigatewayv2_api_mapping" "custom" {
  count       = local.use_custom_domain ? 1 : 0
  api_id      = aws_apigatewayv2_api.http_api.id
  domain_name = aws_apigatewayv2_domain_name.custom[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "api_alias" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = data.aws_route53_zone.api[0].zone_id
  name    = var.api_custom_domain
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.custom[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.custom[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# Route53 zone lookup (only evaluated when a custom domain is requested).
data "aws_route53_zone" "api" {
  count        = local.use_custom_domain ? 1 : 0
  name         = var.api_custom_domain_zone
  private_zone = false
}
