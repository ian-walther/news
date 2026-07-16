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
import { chromium } from "playwright";

const IMPLEMENTATION = "extraction.headless_browser";
const DEFAULT_SETTLE_TIMEOUT_MS = 2_000;

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
  const settleTimeoutMs = Math.min(DEFAULT_SETTLE_TIMEOUT_MS, Math.floor(timeoutMs / 4));
  let browser;

  try {
    const launcher = options.chromiumLauncher ?? chromium;
    browser = await launcher.launch({
      headless: true,
      args: ["--disable-dev-shm-usage"]
    });

    const context = await browser.newContext({
      locale: "en-US",
      userAgent: request.options?.user_agent || browserUserAgent(browser.version()),
      viewport: { width: 1440, height: 1200 }
    });
    const page = await context.newPage();
    const response = await page.goto(request.url, {
      waitUntil: "domcontentloaded",
      timeout: Math.max(timeoutMs - settleTimeoutMs, 1_000)
    });

    await settlePage(page, settleTimeoutMs);

    const finalUrl = page.url() || request.url;
    const statusCode = response?.status() ?? null;
    const headers = response ? await response.allHeaders() : {};
    const contentType = headers["content-type"] || "";
    const retryAfterMs = parseRetryAfter(headers["retry-after"]);

    if (statusCode && (statusCode < 200 || statusCode >= 400)) {
      const httpFailure = classifyHttpFailure(statusCode);

      return failure({
        schemaVersion,
        implementation: IMPLEMENTATION,
        failureKind: httpFailure.failureKind,
        retryable: httpFailure.retryable,
        message: `HTTP ${statusCode}`,
        finalUrl,
        statusCode,
        retryAfterMs,
        startedAt,
        debugMetadata: { browser: "chromium" }
      });
    }

    if (contentType && !contentType.toLowerCase().includes("html")) {
      return failure({
        schemaVersion,
        implementation: IMPLEMENTATION,
        failureKind: "unsupported_content_type",
        retryable: false,
        message: `Unsupported content type: ${contentType}`,
        finalUrl,
        statusCode,
        startedAt,
        debugMetadata: { browser: "chromium" }
      });
    }

    const html = await page.content();

    return extractArticleFromHtml({
      schemaVersion,
      implementation: IMPLEMENTATION,
      html,
      finalUrl,
      minimumTextLength,
      startedAt,
      debugMetadata: {
        browser: "chromium",
        browser_version: browser.version(),
        status_code: statusCode,
        content_type: contentType,
        rendered_html_bytes: html.length
      }
    });
  } catch (error) {
    const failureKind = browserFailureKind(error);

    return failure({
      schemaVersion,
      implementation: IMPLEMENTATION,
      failureKind,
      retryable: failureKind === "browser_error" || retryableError(error),
      message: error instanceof Error ? error.message : String(error),
      startedAt,
      debugMetadata: { browser: "chromium" }
    });
  } finally {
    await browser?.close();
  }
}

async function settlePage(page, timeoutMs) {
  if (timeoutMs <= 0) {
    return;
  }

  try {
    await page.waitForLoadState("networkidle", { timeout: timeoutMs });
  } catch (error) {
    if (error?.name !== "TimeoutError") {
      throw error;
    }
  }
}

function browserUserAgent(version) {
  return `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${version} Safari/537.36`;
}

function browserFailureKind(error) {
  const classified = classifyError(error);

  if (classified !== "unknown") {
    return classified;
  }

  const message = error instanceof Error ? error.message : String(error);

  if (/executable doesn.t exist|browser.*not found/i.test(message)) {
    return "browser_unavailable";
  }

  return "browser_error";
}
