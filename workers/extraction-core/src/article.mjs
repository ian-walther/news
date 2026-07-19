import { Readability } from "@mozilla/readability";
import { JSDOM, VirtualConsole } from "jsdom";
import sanitizeHtml from "sanitize-html";

export const DEFAULT_TIMEOUT_MS = 20_000;
export const DEFAULT_MINIMUM_TEXT_LENGTH = 500;

const STRUCTURAL_BOILERPLATE_SELECTORS = [
  "footer",
  "nav",
  "[role='contentinfo']",
  "[role='navigation']",
  "[aria-label*='footer' i]",
  "[aria-label*='navigation' i]",
  "[data-testid*='footer' i]",
  "[class*='site-footer' i]",
  "[class*='site_footer' i]",
  "[id*='site-footer' i]",
  "[id*='site_footer' i]"
];

const BOILERPLATE_PATTERNS = [
  /\bprivacy policy\b/i,
  /\bterms (?:&|and|of) (?:conditions|service|use)\b/i,
  /\buser agreement\b/i,
  /\ball rights reserved\b/i,
  /\bcopyright\b/i,
  /\bconsent preferences\b/i,
  /\bcalifornia privacy rights\b/i,
  /\baccessibility help\b/i,
  /\bad choices\b/i,
  /\bcontact us\b/i,
  /\bmaterial (?:on this site )?may not be (?:published|reproduced|distributed)\b/i,
  /\bnot to be redistributed, copied, or modified\b/i,
  /\bwe use essential cookies\b/i,
  /\bnon-essential cookies to\b/i,
  /\bby (?:clicking|selecting) .{0,20}accept\b/i,
  /\bchange your cookie settings\b/i
];

const STRONG_BOILERPLATE_PATTERNS = [
  /\ball rights reserved\b/i,
  /\bcopyright\b/i,
  /\bmaterial (?:on this site )?may not be (?:published|reproduced|distributed)\b/i,
  /\bnot to be redistributed, copied, or modified\b/i
];

export function validateRequest(request, implementation, startedAt) {
  const schemaVersion = request?.schema_version ?? 1;

  if (schemaVersion !== 1) {
    return failure({
      schemaVersion,
      implementation,
      failureKind: "unsupported_schema_version",
      retryable: false,
      message: `Unsupported schema_version: ${schemaVersion}`,
      startedAt
    });
  }

  if (!request?.url || typeof request.url !== "string") {
    return failure({
      schemaVersion,
      implementation,
      failureKind: "invalid_request",
      retryable: false,
      message: "Request must include a string url",
      startedAt
    });
  }

  return null;
}

export function extractArticleFromHtml({
  schemaVersion,
  implementation,
  html,
  finalUrl,
  minimumTextLength,
  startedAt,
  debugMetadata = {}
}) {
  const parsed = parseReadableArticle(html, finalUrl);
  const contentText = normalizeText(parsed.textContent);
  const contentHtml = sanitizeArticleHtml(parsed.content, finalUrl);
  const quality = scoreQuality(contentText, parsed, minimumTextLength);

  if (quality.score < 0.35) {
    return failure({
      schemaVersion,
      implementation,
      failureKind: "insufficient_content",
      retryable: false,
      message: quality.reason,
      finalUrl,
      quality,
      startedAt,
      debugMetadata: {
        ...debugMetadata,
        content_length: contentText.length,
        candidate_content_length: quality.candidate_content_length,
        removed_boilerplate_characters: quality.removed_boilerplate_characters,
        removed_boilerplate_nodes: quality.removed_boilerplate_nodes,
        title_present: Boolean(parsed.title)
      }
    });
  }

  return {
    schema_version: schemaVersion,
    implementation,
    status: "ok",
    final_url: finalUrl,
    title: parsed.title || null,
    byline: parsed.byline || null,
    published_at: extractPublishedAt(html) || null,
    content_html: contentHtml || null,
    content_text: contentText,
    excerpt: parsed.excerpt || null,
    site_name: parsed.siteName || null,
    quality,
    debug_metadata: {
      ...debugMetadata,
      elapsed_ms: elapsedMs(startedAt)
    }
  };
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

export function parseReadableArticle(html, url) {
  const virtualConsole = new VirtualConsole();
  const dom = new JSDOM(html, { url, virtualConsole });
  const structuralCleanup = removeStructuralBoilerplate(dom.window.document);
  const reader = new Readability(dom.window.document, { keepClasses: false });
  const article = reader.parse();

  if (!article) {
    return emptyArticle(structuralCleanup);
  }

  return cleanReadableArticle(article, url, structuralCleanup);
}

export function failure(attrs) {
  return {
    schema_version: attrs.schemaVersion,
    implementation: attrs.implementation,
    status: "failed",
    final_url: attrs.finalUrl || null,
    failure_kind: attrs.failureKind,
    retryable: attrs.retryable,
    message: attrs.message,
    quality: attrs.quality || null,
    debug_metadata: {
      status_code: attrs.statusCode ?? null,
      retry_after_ms: attrs.retryAfterMs ?? null,
      elapsed_ms: elapsedMs(attrs.startedAt),
      ...(attrs.debugMetadata || {})
    }
  };
}

export function classifyError(error) {
  const message = error instanceof Error ? error.message : String(error);

  if (error?.name === "AbortError" || error?.name === "TimeoutError" || /timeout/i.test(message)) {
    return "timeout";
  }

  if (error instanceof TypeError || /net::ERR_|ECONN|ENOTFOUND|EAI_AGAIN/.test(message)) {
    return "network_error";
  }

  return "unknown";
}

export function classifyHttpFailure(statusCode) {
  if (statusCode === 429) {
    return { failureKind: "rate_limited", retryable: true };
  }

  if (statusCode === 404 || statusCode === 410) {
    return { failureKind: "not_found", retryable: false };
  }

  if (statusCode === 401 || statusCode === 403) {
    return { failureKind: "blocked", retryable: false };
  }

  return { failureKind: "http_error", retryable: statusCode >= 500 };
}

export function retryableError(error) {
  return ["timeout", "network_error"].includes(classifyError(error));
}

export function parseRetryAfter(value) {
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

export function elapsedMs(startedAt) {
  return new Date().getTime() - startedAt.getTime();
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
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function scoreQuality(contentText, parsed, minimumTextLength) {
  const contentLength = contentText.length;
  const cleanup = parsed.newspaperCleanup || {};
  const metrics = {
    content_length: contentLength,
    candidate_content_length: cleanup.candidateContentLength ?? contentLength,
    removed_boilerplate_characters: cleanup.removedCharacters ?? 0,
    removed_boilerplate_nodes: cleanup.removedNodes ?? 0
  };

  if (!parsed.content || contentLength === 0) {
    const reason = cleanup.boilerplateOnly
      ? "boilerplate_only"
      : "readability_returned_no_content";

    return { score: 0, reason, ...metrics };
  }

  if (contentLength < minimumTextLength) {
    return {
      score: Math.max(0.1, contentLength / minimumTextLength / 2),
      reason: `content_text_shorter_than_${minimumTextLength}`,
      ...metrics
    };
  }

  return {
    score: Number(Math.min(1, 0.5 + contentLength / 4_000).toFixed(2)),
    reason: "sufficient_content",
    ...metrics
  };
}

function cleanReadableArticle(article, url, structuralCleanup) {
  const candidateContentLength = normalizeText(article.textContent).length;
  const virtualConsole = new VirtualConsole();
  const dom = new JSDOM(`<body>${article.content || ""}</body>`, {
    url,
    virtualConsole
  });
  const semanticCleanup = removeSemanticBoilerplate(dom.window.document);
  const content = dom.window.document.body.innerHTML.trim();
  const cleanedText = normalizeText(dom.window.document.body.textContent);
  const boilerplateOnly =
    semanticCleanup.removedNodes > 0 &&
    cleanedText.length <= 100 &&
    semanticCleanup.removedCharacters > cleanedText.length;
  const textContent = boilerplateOnly ? "" : cleanedText;

  return {
    ...article,
    content: textContent ? content : null,
    textContent,
    length: textContent.length,
    newspaperCleanup: {
      candidateContentLength,
      removedCharacters: structuralCleanup.removedCharacters + semanticCleanup.removedCharacters,
      removedNodes: structuralCleanup.removedNodes + semanticCleanup.removedNodes,
      boilerplateOnly
    }
  };
}

function emptyArticle(cleanup) {
  return {
    title: null,
    byline: null,
    content: null,
    textContent: "",
    length: 0,
    excerpt: null,
    siteName: null,
    newspaperCleanup: {
      candidateContentLength: cleanup.removedCharacters,
      removedCharacters: cleanup.removedCharacters,
      removedNodes: cleanup.removedNodes,
      boilerplateOnly: cleanup.removedNodes > 0
    }
  };
}

function removeStructuralBoilerplate(document) {
  return removeNodes(document.querySelectorAll(STRUCTURAL_BOILERPLATE_SELECTORS.join(",")));
}

function removeSemanticBoilerplate(document) {
  const candidates = [...document.querySelectorAll("p, li, ul, ol, section, div")].sort(
    (left, right) => elementDepth(right) - elementDepth(left)
  );
  let removedCharacters = 0;
  let removedNodes = 0;

  for (const node of candidates) {
    if (!node.isConnected || !boilerplateNode(node)) {
      continue;
    }

    removedCharacters += normalizeText(node.textContent).length;
    removedNodes += 1;
    node.remove();
  }

  return { removedCharacters, removedNodes };
}

function boilerplateNode(node) {
  const text = normalizeText(node.textContent);

  if (!text || text.length > 2_000) {
    return false;
  }

  const markerCount = matchingPatternCount(text, BOILERPLATE_PATTERNS);
  const strongMarker = matchingPatternCount(text, STRONG_BOILERPLATE_PATTERNS) > 0;

  if (markerCount >= 3 || (strongMarker && markerCount >= 2)) {
    return true;
  }

  const links = [...node.querySelectorAll("a")];

  if (links.length < 2 || text.length > 600) {
    return false;
  }

  const linkTextLength = normalizeText(links.map(link => link.textContent).join(" ")).length;
  return linkTextLength / text.length >= 0.8;
}

function removeNodes(nodes) {
  let removedCharacters = 0;
  let removedNodes = 0;

  for (const node of nodes) {
    if (!node.isConnected) {
      continue;
    }

    removedCharacters += normalizeText(node.textContent).length;
    removedNodes += 1;
    node.remove();
  }

  return { removedCharacters, removedNodes };
}

function matchingPatternCount(text, patterns) {
  return patterns.filter(pattern => pattern.test(text)).length;
}

function elementDepth(element) {
  let depth = 0;
  let parent = element.parentElement;

  while (parent) {
    depth += 1;
    parent = parent.parentElement;
  }

  return depth;
}

function normalizeText(text) {
  return (text || "").replace(/\s+/g, " ").trim();
}
