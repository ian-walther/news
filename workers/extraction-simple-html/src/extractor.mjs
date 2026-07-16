import { Readability } from "@mozilla/readability";
import { JSDOM, VirtualConsole } from "jsdom";
import sanitizeHtml from "sanitize-html";

const IMPLEMENTATION = "extraction.simple_html";
const DEFAULT_TIMEOUT_MS = 20_000;
const MIN_TEXT_LENGTH = 500;

export async function extractFromRequest(request, options = {}) {
  const schemaVersion = request?.schema_version ?? 1;
  const startedAt = new Date();

  if (schemaVersion !== 1) {
    return failure({
      schemaVersion,
      failureKind: "unsupported_schema_version",
      retryable: false,
      message: `Unsupported schema_version: ${schemaVersion}`,
      startedAt
    });
  }

  if (!request?.url || typeof request.url !== "string") {
    return failure({
      schemaVersion,
      failureKind: "invalid_request",
      retryable: false,
      message: "Request must include a string url",
      startedAt
    });
  }

  const timeoutMs = request.options?.timeout_ms ?? DEFAULT_TIMEOUT_MS;
  const minimumTextLength = request.options?.minimum_text_length ?? MIN_TEXT_LENGTH;

  try {
    const fetched = await fetchHtml(request.url, {
      fetchImpl: options.fetchImpl,
      timeoutMs,
      userAgent: request.options?.user_agent
    });

    if (!fetched.ok) {
      return failure({
        schemaVersion,
        failureKind: fetched.failureKind,
        retryable: fetched.retryable,
        message: fetched.message,
        finalUrl: fetched.finalUrl,
        statusCode: fetched.statusCode,
        retryAfterMs: fetched.retryAfterMs,
        startedAt
      });
    }

    const parsed = parseReadableArticle(fetched.html, fetched.finalUrl);
    const contentText = normalizeText(parsed.textContent);
    const contentHtml = sanitizeArticleHtml(parsed.content, fetched.finalUrl);
    const quality = scoreQuality(contentText, parsed, minimumTextLength);

    if (quality.score < 0.35) {
      return failure({
        schemaVersion,
        failureKind: "insufficient_content",
        retryable: false,
        message: quality.reason,
        finalUrl: fetched.finalUrl,
        statusCode: fetched.statusCode,
        quality,
        startedAt,
        debugMetadata: {
          content_length: contentText.length,
          title_present: Boolean(parsed.title)
        }
      });
    }

    return {
      schema_version: schemaVersion,
      implementation: IMPLEMENTATION,
      status: "ok",
      final_url: fetched.finalUrl,
      title: parsed.title || null,
      byline: parsed.byline || null,
      published_at: extractPublishedAt(fetched.html) || null,
      content_html: contentHtml || null,
      content_text: contentText,
      excerpt: parsed.excerpt || null,
      site_name: parsed.siteName || null,
      quality,
      debug_metadata: {
        status_code: fetched.statusCode,
        content_type: fetched.contentType,
        fetched_bytes: fetched.html.length,
        elapsed_ms: elapsedMs(startedAt)
      }
    };
  } catch (error) {
    return failure({
      schemaVersion,
      failureKind: classifyError(error),
      retryable: retryableError(error),
      message: error instanceof Error ? error.message : String(error),
      startedAt
    });
  }
}

export function sanitizeArticleHtml(html, baseUrl) {
  if (!html) {
    return null;
  }

  return sanitizeHtml(html, {
    allowedTags: [
      ...sanitizeHtml.defaults.allowedTags,
      "img",
      "figure",
      "figcaption",
      "picture",
      "source"
    ],
    allowedAttributes: {
      a: ["href", "title", "rel"],
      img: ["src", "srcset", "alt", "title", "width", "height", "loading"],
      source: ["src", "srcset", "type", "media"]
    },
    allowedSchemes: ["http", "https", "mailto"],
    transformTags: {
      a: (tagName, attributes) => ({
        tagName,
        attribs: {
          ...attributes,
          href: absoluteUrl(attributes.href, baseUrl),
          rel: "noopener noreferrer"
        }
      }),
      img: (tagName, attributes) => ({
        tagName,
        attribs: {
          ...attributes,
          src: absoluteUrl(attributes.src, baseUrl),
          loading: "lazy"
        }
      }),
      source: (tagName, attributes) => ({
        tagName,
        attribs: {
          ...attributes,
          src: absoluteUrl(attributes.src, baseUrl)
        }
      })
    }
  });
}

function absoluteUrl(value, baseUrl) {
  if (!value) {
    return undefined;
  }

  try {
    return new URL(value, baseUrl).toString();
  } catch {
    return undefined;
  }
}

export function parseReadableArticle(html, url) {
  const virtualConsole = new VirtualConsole();
  const dom = new JSDOM(html, { url, virtualConsole });
  const reader = new Readability(dom.window.document, { keepClasses: false });
  const article = reader.parse();

  if (!article) {
    return {
      title: null,
      byline: null,
      content: null,
      textContent: "",
      excerpt: null,
      siteName: null
    };
  }

  return article;
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
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
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

function extractPublishedAt(html) {
  const virtualConsole = new VirtualConsole();
  const dom = new JSDOM(html, { virtualConsole });
  const document = dom.window.document;

  const selectors = [
    'meta[property="article:published_time"]',
    'meta[name="article:published_time"]',
    'meta[name="pubdate"]',
    'meta[name="publishdate"]',
    'meta[name="date"]',
    "time[datetime]"
  ];

  for (const selector of selectors) {
    const element = document.querySelector(selector);
    const value = element?.getAttribute("content") || element?.getAttribute("datetime");
    const parsed = parseDate(value);

    if (parsed) {
      return parsed;
    }
  }

  return null;
}

function parseDate(value) {
  if (!value) {
    return null;
  }

  const date = new Date(value);

  if (Number.isNaN(date.getTime())) {
    return null;
  }

  return date.toISOString();
}

function parseRetryAfter(value) {
  if (!value) {
    return null;
  }

  const seconds = Number(value);

  if (Number.isFinite(seconds) && seconds >= 0) {
    return Math.round(seconds * 1_000);
  }

  const retryAt = new Date(value);

  if (Number.isNaN(retryAt.getTime())) {
    return null;
  }

  return Math.max(retryAt.getTime() - Date.now(), 0);
}

function scoreQuality(contentText, parsed, minimumTextLength) {
  const contentLength = contentText.length;

  if (!parsed.content || contentLength === 0) {
    return { score: 0, reason: "readability_returned_no_content" };
  }

  if (contentLength < minimumTextLength) {
    return {
      score: Math.max(0.1, contentLength / minimumTextLength / 2),
      reason: `content_text_shorter_than_${minimumTextLength}`
    };
  }

  const score = Math.min(1, 0.5 + contentLength / 4_000);

  return {
    score: Number(score.toFixed(2)),
    reason: "sufficient_content"
  };
}

function failure(attrs) {
  return {
    schema_version: attrs.schemaVersion,
    implementation: IMPLEMENTATION,
    status: "failed",
    final_url: attrs.finalUrl || null,
    failure_kind: attrs.failureKind,
    retryable: attrs.retryable,
    message: attrs.message,
    quality: attrs.quality || null,
    debug_metadata: {
      status_code: attrs.statusCode || null,
      retry_after_ms: attrs.retryAfterMs || null,
      elapsed_ms: elapsedMs(attrs.startedAt),
      ...(attrs.debugMetadata || {})
    }
  };
}

function classifyError(error) {
  if (error?.name === "AbortError") {
    return "timeout";
  }

  if (error instanceof TypeError) {
    return "network_error";
  }

  return "unknown";
}

function classifyHttpFailure(statusCode) {
  if (statusCode === 429) {
    return { failureKind: "rate_limited", retryable: true };
  }

  if (statusCode === 401 || statusCode === 403) {
    return { failureKind: "blocked", retryable: false };
  }

  return { failureKind: "http_error", retryable: statusCode >= 500 };
}

function retryableError(error) {
  return classifyError(error) === "timeout" || classifyError(error) === "network_error";
}

function normalizeText(text) {
  return (text || "").replace(/\s+/g, " ").trim();
}

function elapsedMs(startedAt) {
  return new Date().getTime() - startedAt.getTime();
}
