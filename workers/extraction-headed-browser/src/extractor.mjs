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

const IMPLEMENTATION = "extraction.headed_browser";
const DEFAULT_CDP_ENDPOINT = "http://127.0.0.1:9222";
const DEFAULT_SETTLE_TIMEOUT_MS = 2_000;

const AUTH_REQUIRED_PATTERNS = [
  /\bsign in to (?:continue|keep) reading\b/i,
  /\bplease sign in to (?:continue|read)\b/i,
  /\bsign in or create (?:an )?account to continue\b/i,
  /\byour (?:login )?session has expired\b/i
];

const PAYWALL_PATTERNS = [
  /\bsubscribe to continue reading\b/i,
  /\bsubscribe to read (?:the )?(?:full )?article\b/i,
  /\bunlock this article with (?:a|your) subscription\b/i,
  /\bthis article is (?:only )?for subscribers\b/i
];

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
  const cdpEndpoint =
    options.cdpEndpoint ??
    process.env.NEWSPAPER_HEADED_BROWSER_CDP_URL ??
    DEFAULT_CDP_ENDPOINT;
  let browser;
  let page;

  try {
    const connector = options.chromiumConnector ?? chromium;
    const fetchImplementation = options.fetch ?? globalThis.fetch;
    const webSocketEndpoint = await resolveCdpWebSocketEndpoint(
      cdpEndpoint,
      fetchImplementation,
      timeoutMs
    );

    browser = await connector.connectOverCDP(webSocketEndpoint, {
      timeout: timeoutMs
    });

    const [context] = browser.contexts();

    if (!context) {
      throw new Error("Persistent Chrome has no reusable browser context");
    }

    page = await context.newPage();

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
        failureKind: statusCode === 401 ? "auth_required" : httpFailure.failureKind,
        retryable: statusCode === 401 || httpFailure.retryable,
        message:
          statusCode === 401
            ? "The signed-in browser session is no longer authorized"
            : `HTTP ${statusCode}`,
        finalUrl,
        statusCode,
        retryAfterMs,
        startedAt,
        debugMetadata: browserMetadata(browser)
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
        debugMetadata: browserMetadata(browser)
      });
    }

    const html = await page.content();
    const accessBarrier = detectAccessBarrier(html, finalUrl);

    if (accessBarrier) {
      return failure({
        schemaVersion,
        implementation: IMPLEMENTATION,
        failureKind: accessBarrier.failureKind,
        retryable: true,
        message: accessBarrier.message,
        finalUrl,
        statusCode,
        startedAt,
        debugMetadata: {
          ...browserMetadata(browser),
          access_barrier_signal: accessBarrier.signal,
          rendered_html_bytes: html.length
        }
      });
    }

    return extractArticleFromHtml({
      schemaVersion,
      implementation: IMPLEMENTATION,
      html,
      finalUrl,
      minimumTextLength,
      startedAt,
      debugMetadata: {
        ...browserMetadata(browser),
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
      retryable: failureKind === "browser_unavailable" || retryableError(error),
      message: error instanceof Error ? error.message : String(error),
      startedAt,
      debugMetadata: {
        browser: "chrome",
        browser_session: "persistent"
      }
    });
  } finally {
    await closeQuietly(page);
    await closeQuietly(browser);
  }
}

export async function resolveCdpWebSocketEndpoint(
  endpoint,
  fetchImplementation = globalThis.fetch,
  timeoutMs = DEFAULT_TIMEOUT_MS
) {
  if (/^wss?:\/\//i.test(endpoint)) {
    return endpoint;
  }

  const metadataUrl = new URL(endpoint);
  metadataUrl.pathname = `${metadataUrl.pathname.replace(/\/+$/, "")}/json/version`;
  metadataUrl.search = "";
  metadataUrl.hash = "";

  const response = await fetchImplementation(metadataUrl.toString(), {
    signal: AbortSignal.timeout(timeoutMs)
  });

  if (!response.ok) {
    throw new Error(`Chrome CDP endpoint returned HTTP ${response.status}`);
  }

  const metadata = await response.json();

  if (!metadata.webSocketDebuggerUrl) {
    throw new Error("Chrome CDP metadata did not include a WebSocket endpoint");
  }

  const webSocketEndpoint = new URL(metadata.webSocketDebuggerUrl);
  webSocketEndpoint.protocol = metadataUrl.protocol === "https:" ? "wss:" : "ws:";
  webSocketEndpoint.host = metadataUrl.host;

  return webSocketEndpoint.toString();
}

export function detectAccessBarrier(html, finalUrl) {
  const text = visibleText(html);
  const authSignal = AUTH_REQUIRED_PATTERNS.find(pattern => pattern.test(text));

  if (authSignal) {
    return {
      failureKind: "auth_required",
      message: "The signed-in browser session must be refreshed",
      signal: authSignal.source
    };
  }

  if (loginPageWithPassword(html, finalUrl)) {
    return {
      failureKind: "auth_required",
      message: "The signed-in browser session redirected to a login page",
      signal: "login_redirect"
    };
  }

  const paywallSignal = PAYWALL_PATTERNS.find(pattern => pattern.test(text));

  if (paywallSignal) {
    return {
      failureKind: "paywall",
      message: "The authenticated browser reached a subscription barrier",
      signal: paywallSignal.source
    };
  }

  return null;
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

function visibleText(html) {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;|&#160;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function loginPageWithPassword(html, finalUrl) {
  let pathname = "";
  let hostname = "";

  try {
    const url = new URL(finalUrl);
    pathname = url.pathname;
    hostname = url.hostname;
  } catch {
    return false;
  }

  const loginLocation =
    /(?:^|[./_-])(?:login|log-in|signin|sign-in)(?:$|[/?._-])/i.test(
      `${hostname}${pathname}`
    );
  const passwordField = /<input\b[^>]*type=["']?password\b/i.test(html);

  return loginLocation && passwordField;
}

function browserMetadata(browser) {
  return {
    browser: "chrome",
    browser_session: "persistent",
    browser_version: browser.version()
  };
}

function browserFailureKind(error) {
  const classified = classifyError(error);

  if (classified === "timeout") {
    return classified;
  }

  const message = error instanceof Error ? error.message : String(error);

  if (
    /ECONNREFUSED|WebSocket.*(?:closed|error)|DevTools|CDP endpoint|browser context/i.test(
      message
    )
  ) {
    return "browser_unavailable";
  }

  if (classified !== "unknown") {
    return classified;
  }

  return "browser_error";
}

async function closeQuietly(resource) {
  try {
    await resource?.close();
  } catch {
    // The worker result is more useful than a cleanup error after extraction.
  }
}
