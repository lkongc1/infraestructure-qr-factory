// QR Factory - QR generator Lambda handler.
//
// AWS Lambda (Node.js 20.x, arm64). Instrumented with Powertools
// (Logger/Metrics/Tracer) emitting CloudWatch Embedded Metric Format (EMF).
//
// Request flow (matches architecture data flow #4):
//   1. Validate input URL (scheme allowlist + blocklist + canonicalization).
//   2. Atomic quota check (DynamoDB UpdateItem with ConditionExpression).
//   3. Strong-consistent Template read from DynamoDB (optional styling).
//   4. Render QR PNG in RAM (no disk writes).
//   5. PutObject to the private assets bucket (SSE-S3) with retry + jitter.
//   6. Generate a 1h presigned GET URL.
//   7. Return { qrId, url, quotaRemaining }.
//
// Idempotency / failure semantics:
//   * qrId is a fresh UUID4 per invocation.
//   * Quota is incremented ONCE atomically. If S3 PutObject fails we do NOT
//     decrement quota (per architecture: idempotency means no rollback). The
//     client retries with a new request, generating a new qrId.
//   * On any failure we return 503 + Retry-After: 30 (never 500).

import { randomUUID } from "node:crypto";
import { Buffer } from "node:buffer";

import { S3Client, PutObjectCommand, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, UpdateCommand, GetCommand } from "@aws-sdk/lib-dynamodb";

import QRCode from "qrcode";

import { Logger } from "@aws-lambda-powertools/logger";
import { Metrics, MetricUnits } from "@aws-lambda-powertools/metrics";
import { Tracer } from "@aws-lambda-powertools/tracer";

// --- Powertools singletons --------------------------------------------------
// Namespace drives the CloudWatch metric namespace consumed by observability.tf.
const logger = new Logger({ serviceName: process.env.POWERTOOLS_SERVICE_NAME || "qr-factory" });
const metrics = new Metrics({ namespace: process.env.POWERTOOLS_METRICS_NAMESPACE || "QRFactory" });
const tracer = new Tracer({ serviceName: process.env.POWERTOOLS_SERVICE_NAME || "qr-factory" });

// --- Configuration ----------------------------------------------------------
const ASSETS_BUCKET = process.env.ASSETS_BUCKET;
const TEMPLATES_TABLE = process.env.TEMPLATES_TABLE;
const QUOTAS_TABLE = process.env.QUOTAS_TABLE;
const QUOTA_LIMIT = parseInt(process.env.QUOTA_LIMIT_PER_USER || "100", 10);
const PRESIGNED_EXPIRY = parseInt(process.env.PRESIGNED_URL_EXPIRY_SECONDS || "3600", 10);

const ALLOWED_SCHEMES = new Set(["http", "https", "mailto", "tel"]);
const BLOCKED_SCHEMES = new Set(["javascript", "data", "vbs", "file", "vbscript"]);

const AWS_REGION = process.env.AWS_REGION || "us-east-1";

// AWS SDK v3 clients. S3 has its own manual retry loop below for explicit
// jitter control; these are the ambient defaults (retry mode standard).
const s3 = new S3Client({ region: AWS_REGION });
const ddbClient = new DynamoDBClient({ region: AWS_REGION });
const ddb = DynamoDBDocumentClient.from(ddbClient);

// --- Error types ------------------------------------------------------------

class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.name = "ValidationError";
  }
}

class QuotaExceededError extends Error {
  constructor(message) {
    super(message);
    this.name = "QuotaExceededError";
  }
}

// String.prototype.partition helper (mirrors Python str.partition).
// Defined before canonicalizeUrl because prototype assignments are NOT hoisted.
String.prototype.partition = function (sep) {
  const idx = this.indexOf(sep);
  if (idx === -1) return [this.valueOf(), "", ""];
  return [this.slice(0, idx), sep, this.slice(idx + sep.length)];
};

// --- Validation -------------------------------------------------------------

/**
 * Validate and canonicalize the user-supplied URL/string.
 *
 * Allowlist: http, https, mailto, tel.
 * Blocklist: javascript, data, vbs (and a few extras for defense in depth).
 */
function canonicalizeUrl(raw) {
  if (!raw || typeof raw !== "string") {
    throw new ValidationError("url is required");
  }

  const value = raw.trim();
  // Reject NUL / control chars that could smuggle payload fragments.
  if (Array.from(value).some((ch) => ch.charCodeAt(0) < 32)) {
    throw new ValidationError("url contains control characters");
  }

  // Parse with URL. For non-special schemes (mailto, tel) URL is lenient,
  // so we split manually on the first ':'.
  const colonIdx = value.indexOf(":");
  if (colonIdx === -1) {
    throw new ValidationError("url is missing a scheme");
  }
  const scheme = value.slice(0, colonIdx).toLowerCase();

  if (BLOCKED_SCHEMES.has(scheme)) {
    throw new ValidationError(`scheme '${scheme}' is blocked`);
  }
  if (!ALLOWED_SCHEMES.has(scheme)) {
    throw new ValidationError(`scheme '${scheme}' is not allowed`);
  }

  if (scheme === "http" || scheme === "https") {
    // Use WHATWG URL for http/https canonicalization.
    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      throw new ValidationError("invalid url");
    }
    let netloc = parsed.hostname.toLowerCase();
    if (parsed.port) {
      const defaultPort = scheme === "http" ? "80" : "443";
      if (parsed.port === defaultPort) {
        // drop default port
      } else {
        netloc = `${netloc}:${parsed.port}`;
      }
    }
    if (!netloc) {
      throw new ValidationError("url is missing a host");
    }
    // Reject userinfo smuggling.
    if (parsed.username || parsed.password) {
      throw new ValidationError("userinfo in url is not allowed");
    }
    const path = parsed.pathname || "/";
    // search already normalized by URL; no fragment.
    const canonical = `${scheme}://${netloc}${path}${parsed.search ? parsed.search : ""}`;
    return canonical;
  }

  if (scheme === "mailto") {
    // mailto:address?subject=... — validate the address part.
    const rest = value.slice(colonIdx + 1);
    // Strip any query/fragment for address validation.
    const qIdx = rest.search(/[?#]/);
    const addressPart = (qIdx === -1 ? rest : rest.slice(0, qIdx)).trim();
    let address;
    try {
      address = decodeURIComponent(addressPart);
    } catch {
      address = addressPart;
    }
    address = address.trim().toLowerCase();
    if (!address || !address.includes("@")) {
      throw new ValidationError("invalid mailto address");
    }
    const [local, , domain] = address.partition("@");
    if (!local || !domain || !domain.includes(".")) {
      throw new ValidationError("invalid mailto address");
    }
    return `mailto:${address}`;
  }

  if (scheme === "tel") {
    const number = value.slice(colonIdx + 1).trim();
    const cleaned = Array.from(number)
      .filter((ch) => "+-() 0123456789".includes(ch))
      .join("");
    if (!cleaned || !Array.from(cleaned).some((ch) => ch >= "0" && ch <= "9")) {
      throw new ValidationError("invalid tel number");
    }
    return `tel:${cleaned}`;
  }

  // Unreachable due to allowlist check, but keeps the function total.
  throw new ValidationError("unsupported scheme");
}

// --- Quota (atomic counter, strong consistency) -----------------------------

/**
 * Atomically increment the user's daily counter and return remaining quota.
 *
 * Uses UpdateItem with a ConditionExpression so the increment + limit check is
 * a single strongly-consistent operation (no read-then-write race). The row
 * carries an expiresAt TTL so counters reset daily.
 */
async function consumeQuota(userId) {
  const expiresAt = Math.floor(Date.now() / 1000) + 86400;

  const segment = tracer.getSegment();
  const subsegment = segment ? segment.addNewSubsegment("consumeQuota") : null;

  try {
    const response = await ddb.send(
      new UpdateCommand({
        TableName: QUOTAS_TABLE,
        Key: { userId },
        UpdateExpression:
          "SET usedCount = if_not_exists(usedCount, :zero) + :inc, expiresAt = :expires",
        ConditionExpression: "attribute_not_exists(usedCount) OR usedCount < :limit",
        ExpressionAttributeValues: {
          ":zero": 0,
          ":inc": 1,
          ":limit": QUOTA_LIMIT,
          ":expires": expiresAt,
        },
        ReturnValues: "UPDATED_NEW",
      })
    );

    const used = (response.Attributes && response.Attributes.usedCount) || 0;
    const remaining = Math.max(QUOTA_LIMIT - used, 0);
    return remaining;
  } catch (err) {
    const code = err && err.name ? err.name : "";
    if (code === "ConditionalCheckFailedException") {
      throw new QuotaExceededError("daily QR quota exceeded");
    }
    throw err;
  } finally {
    if (subsegment) subsegment.close();
  }
}

// --- Template (strong-consistent read) --------------------------------------

/**
 * Return the template styling dict, or defaults if no template requested.
 */
async function getTemplate(templateId) {
  const segment = tracer.getSegment();
  const subsegment = segment ? segment.addNewSubsegment("getTemplate") : null;

  try {
    if (!templateId) {
      return {
        boxSize: 10,
        border: 4,
        fillColor: "000000",
        backColor: "FFFFFF",
      };
    }

    const response = await ddb.send(
      new GetCommand({
        TableName: TEMPLATES_TABLE,
        Key: { id: templateId },
        ConsistentRead: true,
      })
    );

    const item = response.Item;
    if (!item) {
      throw new ValidationError(`template '${templateId}' not found`);
    }
    return {
      boxSize: typeof item.boxSize === "number" ? item.boxSize : 10,
      border: typeof item.border === "number" ? item.border : 4,
      fillColor: typeof item.fillColor === "string" ? item.fillColor : "000000",
      backColor: typeof item.backColor === "string" ? item.backColor : "FFFFFF",
    };
  } finally {
    if (subsegment) subsegment.close();
  }
}

// --- QR rendering (in RAM) --------------------------------------------------

/**
 * Render the QR code to PNG bytes entirely in memory.
 */
async function renderQrPng(data, template) {
  const segment = tracer.getSegment();
  const subsegment = segment ? segment.addNewSubsegment("renderQrPng") : null;

  try {
    // qrcode library: toBuffer returns a Node Buffer with PNG bytes.
    // Colors: qrcode uses hex with leading '#'.
    const pngBuffer = await QRCode.toBuffer(data, {
      type: "png",
      errorCorrectionLevel: "M",
      margin: template.border,
      scale: template.boxSize, // pixels per module
      color: {
        dark: `#${template.fillColor}`,
        light: `#${template.backColor}`,
      },
    });

    // Sanitize output: PNG magic header must be present.
    const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    if (pngBuffer.length < 8 || pngBuffer.subarray(0, 8).equals(PNG_MAGIC) === false) {
      throw new Error("generated QR is not a valid PNG");
    }
    return pngBuffer;
  } finally {
    if (subsegment) subsegment.close();
  }
}

// --- S3 PutObject with explicit retry + jitter ------------------------------

/**
 * PutObject to the private assets bucket (SSE-S3) with 3 retries.
 *
 * Backoff: 1s, 2s, 4s + up to 25% jitter. On terminal failure the exception
 * propagates so the handler can return 503. Quota is NOT rolled back.
 */
async function putObjectWithRetry(bucket, key, body) {
  const maxAttempts = 3;
  let lastError = null;

  const segment = tracer.getSegment();
  const subsegment = segment ? segment.addNewSubsegment("putObjectWithRetry") : null;

  try {
    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await s3.send(
          new PutObjectCommand({
            Bucket: bucket,
            Key: key,
            Body: body,
            ContentType: "image/png",
            ServerSideEncryption: "AES256", // SSE-S3
            CacheControl: "private, max-age=3600",
            Metadata: { generator: "qr-factory" },
          })
        );
        return;
      } catch (err) {
        lastError = err;
        if (attempt === maxAttempts) break;
        const baseDelay = 2 ** (attempt - 1); // 1, 2, 4 seconds
        const jitter = Math.random() * baseDelay * 0.25;
        const sleepFor = baseDelay + jitter;
        logger.warning("S3 PutObject failed; retrying", {
          attempt,
          nextRetrySeconds: Number(sleepFor.toFixed(2)),
          error: String(err),
        });
        await new Promise((resolve) => setTimeout(resolve, sleepFor * 1000));
      }
    }
    throw new Error(`S3 PutObject failed after ${maxAttempts} attempts: ${lastError}`);
  } finally {
    if (subsegment) subsegment.close();
  }
}

// --- Presigned URL ----------------------------------------------------------

async function makePresignedGet(bucket, key) {
  const command = new GetObjectCommand({ Bucket: bucket, Key: key });
  return getSignedUrl(s3, command, { expiresIn: PRESIGNED_EXPIRY });
}

// --- Helpers ----------------------------------------------------------------

function extractUserId(event) {
  let claims = {};
  try {
    claims = event.requestContext.authorizer.jwt.claims || {};
  } catch {
    claims = {};
  }
  return String(claims.sub || claims.email || "anonymous");
}

function extractTraceId(event, context) {
  const headers = event.headers || {};
  // HTTP API v2 headers can be lowercased; check common variants.
  const trace =
    headers["x-amzn-trace-id"] ||
    headers["X-Amzn-Trace-Id"] ||
    headers["X-AMZN-TRACE-ID"] ||
    null;
  return trace || (context && context.awsRequestId) || "unknown";
}

function buildResponse(statusCode, payload, retryAfter = null) {
  const headers = { "Content-Type": "application/json" };
  if (retryAfter) headers["Retry-After"] = retryAfter;
  return {
    statusCode,
    headers,
    body: JSON.stringify(payload),
  };
}

// --- Handler ---------------------------------------------------------------

export const handler = async (event, context) => {
  logger.addContext(context);

  const startMs = Date.now();
  const userId = extractUserId(event);
  const traceId = extractTraceId(event, context);
  const qrId = randomUUID();

  tracer.putAnnotation("qrId", qrId);
  tracer.putAnnotation("userId", userId);

  let quotaRemaining = null;

  const finish = (code) => {
    const latencyMs = Number((Date.now() - startMs).toFixed(2));
    metrics.addMetric("Latency", MetricUnits.Milliseconds, latencyMs);
    metrics.addMetric("StatusCode", MetricUnits.Count, code);
    logger.info("request completed", {
      traceId,
      userId,
      qrId,
      latencyMs,
      statusCode: code,
      quotaRemaining,
    });
    return code;
  };

  try {
    // --- Parse body -------------------------------------------------------
    let rawBody = event.body || "{}";
    if (event.isBase64Encoded) {
      rawBody = Buffer.from(rawBody, "base64").toString("utf-8");
    }
    let body;
    try {
      body = JSON.parse(rawBody);
    } catch {
      const code = finish(400);
      return buildResponse(code, { error: "invalid JSON body" });
    }

    const rawUrl = body.url;
    const templateId = body.templateId;

    // --- 1. Validate input ------------------------------------------------
    const canonical = canonicalizeUrl(rawUrl);
    metrics.addMetric("ValidRequests", MetricUnits.Count, 1);

    // --- 2. Quota (atomic) ------------------------------------------------
    quotaRemaining = await consumeQuota(userId);
    metrics.addMetric("QuotaUsage", MetricUnits.Count, QUOTA_LIMIT - quotaRemaining);
    metrics.addMetric("QuotaRemaining", MetricUnits.Count, quotaRemaining);

    // --- 3. Template ------------------------------------------------------
    const template = await getTemplate(templateId);

    // --- 4. Render QR in RAM ----------------------------------------------
    const pngBytes = await renderQrPng(canonical, template);

    // --- 5. PutObject (SSE-S3, retry) -------------------------------------
    const objectKey = `qrs/${userId}/${qrId}.png`;
    await putObjectWithRetry(ASSETS_BUCKET, objectKey, pngBytes);

    // --- 6. Presigned URL (1h) --------------------------------------------
    const urlOut = await makePresignedGet(ASSETS_BUCKET, objectKey);

    // --- 7. Success response ----------------------------------------------
    const statusCode = finish(200);
    return buildResponse(statusCode, {
      qrId,
      url: urlOut,
      quotaRemaining,
    });
  } catch (err) {
    if (err instanceof QuotaExceededError) {
      const code = finish(429);
      metrics.addMetric("QuotaExceeded", MetricUnits.Count, 1);
      return buildResponse(code, { error: "daily quota exceeded", quotaRemaining: 0 }, "3600");
    }
    if (err instanceof ValidationError) {
      const code = finish(400);
      metrics.addMetric("ValidationErrors", MetricUnits.Count, 1);
      return buildResponse(code, { error: err.message });
    }
    // Architecture: return 503 + Retry-After: 30 on failure, never 500.
    logger.error("request failed", {
      error: String(err),
      errorType: err && err.name ? err.name : typeof err,
    });
    const code = finish(503);
    metrics.addMetric("Failures", MetricUnits.Count, 1);
    return buildResponse(code, { error: "service unavailable", qrId }, "30");
  } finally {
    // Flush any stored metrics as EMF so CloudWatch receives them on every path.
    metrics.publishStoredMetrics();
  }
};
