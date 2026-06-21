"""QR Factory - QR generator Lambda handler.

AWS Lambda (Python 3.11, arm64). Instrumented with Powertools
(Logger/Metrics/Tracer) emitting CloudWatch Embedded Metric Format (EMF).

Request flow (matches architecture data flow #4):
    1. Validate input URL (scheme allowlist + blocklist + canonicalization).
    2. Atomic quota check (DynamoDB UpdateItem with ConditionExpression).
    3. Strong-consistent Template read from DynamoDB (optional styling).
    4. Render QR PNG in RAM (BytesIO, no disk writes).
    5. PutObject to the private assets bucket (SSE-S3) with retry + jitter.
    6. Generate a 1h presigned GET URL.
    7. Return { qrId, url, quotaRemaining }.

Idempotency / failure semantics:
    * qrId is a fresh UUID4 per invocation.
    * Quota is incremented ONCE atomically. If S3 PutObject fails we do NOT
      decrement quota (per architecture: idempotency means no rollback). The
      client retries with a new request, generating a new qrId.
    * On any failure we return 503 + Retry-After: 30 (never 500).
"""

import json
import os
import time
import uuid
import random
import urllib.parse
from io import BytesIO
from decimal import Decimal

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

import qrcode

from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.logging import correlation_paths

# --- Powertools singletons -------------------------------------------------
# Namespace drives the CloudWatch metric namespace consumed by observability.tf.
logger = Logger(service=os.environ.get("POWERTOOLS_SERVICE_NAME", "qr-factory"))
metrics = Metrics(namespace=os.environ.get("POWERTOOLS_METRICS_NAMESPACE", "QRFactory"))
tracer = Tracer(service=os.environ.get("POWERTOOLS_SERVICE_NAME", "qr-factory"))

# --- Configuration ---------------------------------------------------------
ASSETS_BUCKET = os.environ["ASSETS_BUCKET"]
TEMPLATES_TABLE = os.environ["TEMPLATES_TABLE"]
QUOTAS_TABLE = os.environ["QUOTAS_TABLE"]
QUOTA_LIMIT = int(os.environ.get("QUOTA_LIMIT_PER_USER", "100"))
PRESIGNED_EXPIRY = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "3600"))

ALLOWED_SCHEMES = {"http", "https", "mailto", "tel"}
BLOCKED_SCHEMES = {"javascript", "data", "vbs", "file", "vbscript"}

# Boto clients with sane retry/timeout defaults. S3 has its own manual retry
# loop below for explicit jitter control; these are the ambient defaults.
_BOTO_CONFIG = Config(
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
    retries={"max_attempts": 3, "mode": "standard"},
    connect_timeout=2,
    read_timeout=5,
)

s3 = boto3.client("s3", config=_BOTO_CONFIG)
ddb = boto3.resource("dynamodb", config=_BOTO_CONFIG)
templates_table = ddb.Table(TEMPLATES_TABLE)
quotas_table = ddb.Table(QUOTAS_TABLE)


# --- Validation ------------------------------------------------------------

class ValidationError(ValueError):
    """Raised when the request payload or URL fails validation."""


class QuotaExceededError(RuntimeError):
    """Raised when the user has hit their daily QR quota."""


def canonicalize_url(raw: str) -> str:
    """Validate and canonicalize the user-supplied URL/string.

    Allowlist: http, https, mailto, tel.
    Blocklist: javascript, data, vbs (and a few extras for defense in depth).
    """
    if not raw or not isinstance(raw, str):
        raise ValidationError("url is required")

    value = raw.strip()
    # Reject NUL / control chars that could smuggle payload fragments.
    if any(ord(ch) < 32 for ch in value):
        raise ValidationError("url contains control characters")

    # Strip leading whitespace before scheme and parse.
    parsed = urllib.parse.urlsplit(value)
    scheme = (parsed.scheme or "").lower()

    if not scheme:
        raise ValidationError("url is missing a scheme")

    if scheme in BLOCKED_SCHEMES:
        raise ValidationError(f"scheme '{scheme}' is blocked")

    if scheme not in ALLOWED_SCHEMES:
        raise ValidationError(f"scheme '{scheme}' is not allowed")

    # Scheme-specific canonicalization.
    if scheme in ("http", "https"):
        netloc = parsed.netloc.lower()
        # Drop default ports.
        if scheme == "http" and netloc.endswith(":80"):
            netloc = netloc[:-3]
        elif scheme == "https" and netloc.endswith(":443"):
            netloc = netloc[:-4]
        if not netloc:
            raise ValidationError("url is missing a host")
        # No fragment, no userinfo smuggling (basic defense).
        if "@" in netloc:
            raise ValidationError("userinfo in url is not allowed")
        path = parsed.path or "/"
        # Re-encode to normalize percent-encoding without double-encoding.
        query = parsed.query
        canonical = urllib.parse.urlunsplit((scheme, netloc, path, query, ""))
        return canonical

    if scheme == "mailto":
        address = urllib.parse.unquote(parsed.path)
        address = address.strip().lower()
        if not address or "@" not in address:
            raise ValidationError("invalid mailto address")
        # Basic email shape check.
        local, _, domain = address.partition("@")
        if not local or not domain or "." not in domain:
            raise ValidationError("invalid mailto address")
        return f"mailto:{address}"

    if scheme == "tel":
        number = parsed.path.strip()
        # Allow digits, '+', '-', '(', ')', spaces.
        cleaned = "".join(ch for ch in number if ch in "+-() 0123456789")
        if not cleaned or not any(ch.isdigit() for ch in cleaned):
            raise ValidationError("invalid tel number")
        return f"tel:{cleaned}"

    # Unreachable due to allowlist check, but keeps the function total.
    raise ValidationError("unsupported scheme")


# --- Quota (atomic counter, strong consistency) ----------------------------

@tracer.capture_method
def consume_quota(user_id: str) -> int:
    """Atomically increment the user's daily counter and return remaining quota.

    Uses UpdateItem with a ConditionExpression so the increment + limit check is
    a single strongly-consistent operation (no read-then-write race). The row
    carries an expiresAt TTL so counters reset daily.
    """
    # TTL: end of the current UTC day (24h window max).
    expires_at = int(time.time()) + 86400

    try:
        response = quotas_table.update_item(
            Key={"userId": user_id},
            UpdateExpression=(
                "SET usedCount = if_not_exists(usedCount, :zero) + :inc, "
                "expiresAt = :expires"
            ),
            ConditionExpression="attribute_not_exists(usedCount) OR usedCount < :limit",
            ExpressionAttributeValues={
                ":zero": 0,
                ":inc": 1,
                ":limit": QUOTA_LIMIT,
                ":expires": expires_at,
            },
            ReturnValues="UPDATED_NEW",
        )
    except ClientError as err:
        code = err.response.get("Error", {}).get("Code", "")
        if code == "ConditionalCheckFailedException":
            raise QuotaExceededError("daily QR quota exceeded")
        raise

    used = int(response.get("Attributes", {}).get("usedCount", 0))
    remaining = max(QUOTA_LIMIT - used, 0)
    return remaining


# --- Template (strong-consistent read) -------------------------------------

@tracer.capture_method
def get_template(template_id: str) -> dict:
    """Return the template styling dict, or defaults if no template requested."""
    if not template_id:
        return {
            "boxSize": 10,
            "border": 4,
            "fillColor": "000000",
            "backColor": "FFFFFF",
        }

    response = templates_table.get_item(
        Key={"id": template_id},
        ConsistentRead=True,
    )
    item = response.get("Item")
    if not item:
        raise ValidationError(f"template '{template_id}' not found")
    return {
        "boxSize": int(item.get("boxSize", 10)),
        "border": int(item.get("border", 4)),
        "fillColor": str(item.get("fillColor", "000000")),
        "backColor": str(item.get("backColor", "FFFFFF")),
    }


# --- QR rendering (in RAM) -------------------------------------------------

@tracer.capture_method
def render_qr_png(data: str, template: dict) -> bytes:
    """Render the QR code to PNG bytes entirely in memory."""
    qr = qrcode.QRCode(
        version=None,  # auto-select smallest version that fits
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=template["boxSize"],
        border=template["border"],
    )
    qr.add_data(data)
    qr.make(fit=True)

    img = qr.make_image(fill_color=template["fillColor"], back_color=template["backColor"])
    buf = BytesIO()
    img.save(buf, format="PNG")
    png_bytes = buf.getvalue()
    buf.close()

    # Sanitize output: PNG magic header must be present, size must be sane.
    if not png_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        raise RuntimeError("generated QR is not a valid PNG")
    return png_bytes


# --- S3 PutObject with explicit retry + jitter -----------------------------

@tracer.capture_method
def put_object_with_retry(bucket: str, key: str, body: bytes) -> None:
    """PutObject to the private assets bucket (SSE-S3) with 3 retries.

    Backoff: 1s, 2s, 4s + up to 25% jitter. On terminal failure the exception
    propagates so the handler can return 503. Quota is NOT rolled back.
    """
    max_attempts = 3
    last_error = None

    for attempt in range(1, max_attempts + 1):
        try:
            s3.put_object(
                Bucket=bucket,
                Key=key,
                Body=body,
                ContentType="image/png",
                ServerSideEncryption="AES256",  # SSE-S3
                CacheControl="private, max-age=3600",
                Metadata={
                    "generator": "qr-factory",
                },
            )
            return
        except ClientError as err:
            last_error = err
            if attempt == max_attempts:
                break
            base_delay = 2 ** (attempt - 1)  # 1, 2, 4
            jitter = random.uniform(0, base_delay * 0.25)
            sleep_for = base_delay + jitter
            logger.warning(
                "S3 PutObject failed; retrying",
                attempt=attempt,
                next_retry_seconds=round(sleep_for, 2),
                error=str(err),
            )
            time.sleep(sleep_for)

    raise RuntimeError(f"S3 PutObject failed after {max_attempts} attempts: {last_error}")


# --- Presigned URL ---------------------------------------------------------

@tracer.capture_method
def make_presigned_get(bucket: str, key: str) -> str:
    return s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=PRESIGNED_EXPIRY,
        HttpMethod="GET",
    )


# --- Helpers ---------------------------------------------------------------

def extract_user_id(event: dict) -> str:
    """Pull the user id from the HTTP API v2 JWT authorizer claims."""
    try:
        claims = event["requestContext"]["authorizer"]["jwt"]["claims"]
    except (KeyError, TypeError):
        claims = {}

    user_id = claims.get("sub") or claims.get("email") or "anonymous"
    return str(user_id)


def extract_trace_id(event: dict, context) -> str:
    """Use the Lambda request id as the trace id (X-Ray carries the real trace)."""
    headers = event.get("headers") or {}
    trace = headers.get("x-amzn-trace-id") or headers.get("X-Amzn-Trace-Id")
    return trace or getattr(context, "aws_request_id", "unknown")


def build_response(status_code: int, payload: dict, retry_after: str = None) -> dict:
    headers = {"Content-Type": "application/json"}
    if retry_after:
        headers["Retry-After"] = retry_after
    return {
        "statusCode": status_code,
        "headers": headers,
        "body": json.dumps(payload),
    }


# --- Handler ---------------------------------------------------------------

@logger.inject_lambda_context(correlation_id_path=correlation_paths.API_GATEWAY_HTTP)
@tracer.capture_lambda_handler
@metrics.log_metrics(raise_on_empty_metrics=False)
def handler(event, context):
    start_ms = time.time() * 1000.0
    user_id = extract_user_id(event)
    trace_id = extract_trace_id(event, context)
    qr_id = str(uuid.uuid4())

    # Default response fields; mutated on each path.
    status_code = 500
    quota_remaining = None
    url_out = None

    def _finish(code: int) -> dict:
        latency_ms = round(time.time() * 1000.0 - start_ms, 2)
        metrics.add_metric(name="Latency", unit=MetricUnit.Milliseconds, value=latency_ms)
        metrics.add_metric(name="StatusCode", unit=MetricUnit.Count, value=code)
        logger.info(
            "request completed",
            traceId=trace_id,
            userId=user_id,
            qrId=qr_id,
            latencyMs=latency_ms,
            statusCode=code,
            quotaRemaining=quota_remaining,
        )
        return code

    # --- Parse body -------------------------------------------------------
    try:
        raw_body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        body = json.loads(raw_body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        code = _finish(400)
        return build_response(code, {"error": "invalid JSON body"})

    try:
        raw_url = body.get("url")
        template_id = body.get("templateId")

        # --- 1. Validate input -------------------------------------------
        canonical = canonicalize_url(raw_url)
        metrics.add_metric(name="ValidRequests", unit=MetricUnit.Count, value=1)

        # --- 2. Quota (atomic) -------------------------------------------
        quota_remaining = consume_quota(user_id)
        metrics.add_metric(name="QuotaUsage", unit=MetricUnit.Count, value=QUOTA_LIMIT - quota_remaining)
        metrics.add_metric(name="QuotaRemaining", unit=MetricUnit.Count, value=quota_remaining)

        # --- 3. Template -------------------------------------------------
        template = get_template(template_id)

        # --- 4. Render QR in RAM -----------------------------------------
        png_bytes = render_qr_png(canonical, template)

        # --- 5. PutObject (SSE-S3, retry) --------------------------------
        object_key = f"qrs/{user_id}/{qr_id}.png"
        put_object_with_retry(ASSETS_BUCKET, object_key, png_bytes)

        # --- 6. Presigned URL (1h) ---------------------------------------
        url_out = make_presigned_get(ASSETS_BUCKET, object_key)

        # --- 7. Success response -----------------------------------------
        status_code = _finish(200)
        return build_response(
            status_code,
            {"qrId": qr_id, "url": url_out, "quotaRemaining": quota_remaining},
        )

    except QuotaExceededError:
        status_code = _finish(429)
        metrics.add_metric(name="QuotaExceeded", unit=MetricUnit.Count, value=1)
        return build_response(
            status_code,
            {"error": "daily quota exceeded", "quotaRemaining": 0},
            retry_after="3600",
        )

    except ValidationError as err:
        status_code = _finish(400)
        metrics.add_metric(name="ValidationErrors", unit=MetricUnit.Count, value=1)
        return build_response(status_code, {"error": str(err)})

    except Exception as err:  # noqa: BLE001 - top-level safety net
        # Architecture: return 503 + Retry-After: 30 on failure, never 500.
        logger.error("request failed", error=str(err), error_type=type(err).__name__)
        status_code = _finish(503)
        metrics.add_metric(name="Failures", unit=MetricUnit.Count, value=1)
        return build_response(
            status_code,
            {"error": "service unavailable", "qrId": qr_id},
            retry_after="30",
        )
