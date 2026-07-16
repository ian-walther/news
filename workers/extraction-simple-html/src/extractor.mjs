import {
  DEFAULT_MINIMUM_TEXT_LENGTH,
  DEFAULT_TIMEOUT_MS,
  classifyError,
  classifyHttpFailure,
  extractArticleFromHtml,
  failure,
  parseRetryAfter,
  retryableError,
  validateRequest
} from "@newspaper/extraction-core";

export { parseReadableArticle, sanitizeArticleHtml } from "@newspaper/extraction-core";

const IMPLEMENTATION = "extraction.simple_html";

export async function extractFromRequest(request, options = {}) {
  const schemaVersion = request?.schema_version ?? 1;
  const startedAt = new Date();
  const validationFailure = validateRequest(request, IMPLEMENTATION, startedAt);

  if (validationFailure) {
    return validationFailure;
  }

  const timeoutMs = request.options?.timeout_ms ?? DEFAULT_TIMEOUT_MS;
  const minimumTextLength =
    request.options?.minimum_text_length ?? DEFAULT_MINIMUM_TEXT_LENGTH;

  try {
    const fetched = await fetchHtml(request.url, {
      fetchImpl: options.fetchImpl,
      timeoutMs,
      userAgent: request.options?.user_agent
    });

    if (!fetched.ok) {
      return failure({
        schemaVersion,
        implementation: IMPLEMENTATION,
        failureKind: fetched.failureKind,
        retryable: fetched.retryable,
        message: fetched.message,
        finalUrl: fetched.finalUrl,
        statusCode: fetched.statusCode,
        retryAfterMs: fetched.retryAfterMs,
        startedAt
      });
    }

    return extractArticleFromHtml({
      schemaVersion,
      implementation: IMPLEMENTATION,
      html: fetched.html,
      finalUrl: fetched.finalUrl,
      minimumTextLength,
      startedAt,
      debugMetadata: {
        status_code: fetched.statusCode,
        content_type: fetched.contentType,
        fetched_bytes: fetched.html.length
      }
    });
  } catch (error) {
    return failure({
      schemaVersion,
      implementation: IMPLEMENTATION,
      failureKind: classifyError(error),
      retryable: retryableError(error),
      message: error instanceof Error ? error.message : String(error),
      startedAt
    });
  }
}

async function fetchHtml(url, options) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);

  try {
    const response = await fetchImpl(url, {
      signal: controller.signal,
      redirect: "follow",
      headers: {
        accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "user-agent":
          options.userAgent ||
          "Mozilla/5.0 (compatible; NewspaperBot/0.1; +https://news.home)"
      }
    });

    const finalUrl = response.url || url;
    const statusCode = response.status;
    const contentType = response.headers.get("content-type") || "";
    const retryAfterMs = parseRetryAfter(response.headers.get("retry-after"));

    if (!response.ok) {
      const httpFailure = classifyHttpFailure(statusCode);

      return {
        ok: false,
        finalUrl,
        statusCode,
        failureKind: httpFailure.failureKind,
        retryable: httpFailure.retryable,
        retryAfterMs,
        message: `HTTP ${statusCode}`
      };
    }

    if (contentType && !contentType.toLowerCase().includes("html")) {
      return {
        ok: false,
        finalUrl,
        statusCode,
        failureKind: "unsupported_content_type",
        retryable: false,
        message: `Unsupported content type: ${contentType}`
      };
    }

    return {
      ok: true,
      finalUrl,
      statusCode,
      contentType,
      html: await response.text()
    };
  } catch (error) {
    return {
      ok: false,
      finalUrl: url,
      failureKind: classifyError(error),
      retryable: retryableError(error),
      message: error instanceof Error ? error.message : String(error)
    };
  } finally {
    clearTimeout(timeout);
  }
}
