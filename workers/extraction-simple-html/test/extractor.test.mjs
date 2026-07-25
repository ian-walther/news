import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  extractFromRequest,
  parseReadableArticle,
  sanitizeArticleHtml
} from "../src/extractor.mjs";
import { parseRetryAfter } from "@newspaper/extraction-core";

test("parseReadableArticle extracts a fixture article", async () => {
  const html = await readFile(new URL("./fixtures/readable-article.html", import.meta.url), "utf8");
  const article = parseReadableArticle(html, "https://example.com/news/great-story");

  assert.equal(article.title, "A Useful Test Article");
  assert.equal(article.byline, "By Ian Example");
  assert.match(article.textContent, /This is the opening paragraph/);
  assert.match(article.textContent, /The extractor should keep article paragraphs/);
});

test("extractFromRequest returns the normalized success contract", async () => {
  const html = await readFile(new URL("./fixtures/readable-article.html", import.meta.url), "utf8");

  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/news/great-story",
      options: { minimum_text_length: 100 }
    },
    { fetchImpl: fixtureFetch(html, "https://example.com/news/great-story") }
  );

  assert.equal(result.schema_version, 1);
  assert.equal(result.implementation, "extraction.simple_html");
  assert.equal(result.status, "ok");
  assert.equal(result.final_url, "https://example.com/news/great-story");
  assert.equal(result.title, "A Useful Test Article");
  assert.equal(result.byline, "By Ian Example");
  assert.equal(result.published_at, "2026-06-18T12:30:00.000Z");
  assert.match(result.content_html, /opening paragraph/);
  assert.match(result.content_text, /article paragraphs/);
  assert.equal(result.quality.reason, "sufficient_content");
});

test("extractFromRequest reports no content as a non-error outcome", async () => {
  const html = "<html><head><title>Tiny</title></head><body><article><p>Too short.</p></article></body></html>";

  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/tiny",
      options: { minimum_text_length: 100 }
    },
    { fetchImpl: fixtureFetch(html, "https://example.com/tiny") }
  );

  assert.equal(result.status, "no_content");
  assert.equal(result.reason, "content_text_shorter_than_100");
  assert.equal(result.failure_kind, undefined);
  assert.equal(result.retryable, undefined);
});

test("extractFromRequest treats minimum text length as a strict floor", async () => {
  const belowMinimum = await extractTextWithLength(499, 500);
  const atMinimum = await extractTextWithLength(500, 500);

  assert.equal(belowMinimum.quality.content_length, 499);
  assert.equal(belowMinimum.status, "no_content");
  assert.equal(belowMinimum.reason, "content_text_shorter_than_500");

  assert.equal(atMinimum.quality.content_length, 500);
  assert.equal(atMinimum.status, "ok");
  assert.equal(atMinimum.quality.reason, "sufficient_content");
});

test("extractFromRequest removes embedded-player chrome without removing article media", async () => {
  const html = await readFixture("article-with-promotional-video-embed.html");
  const result = await extractFixture(html, "https://www.theautopian.com/useful-story/");

  assert.equal(result.status, "ok");
  assert.match(result.content_text, /opening paragraph contains the actual reporting/);
  assert.match(result.content_text, /closing paragraph contains more substantive reporting/);
  assert.match(result.content_html, /editorial-photo\.jpg/);
  assert.match(result.content_html, /legitimate editorial photograph/i);
  assert.doesNotMatch(result.content_html, /vidframe|example-player|youtube\.com|youtu\.be/i);
  assert.doesNotMatch(result.content_text, /video embed above gives you trouble/i);
  assert.ok(result.debug_metadata.removed_embedded_media_nodes >= 2);
});

for (const fixture of [
  "footer-only-racer.html",
  "footer-only-publisher.html",
  "cookie-consent-only.html"
]) {
  test(`extractFromRequest rejects production-derived boilerplate in ${fixture}`, async () => {
    const html = await readFixture(fixture);
    const parsed = parseReadableArticle(html, `https://example.com/${fixture}`);
    const result = await extractFixture(html, `https://example.com/${fixture}`);

    assert.equal(parsed.length, 0);
    assert.equal(result.status, "no_content");
    assert.equal(result.reason, "boilerplate_only");
    assert.equal(result.failure_kind, undefined);
    assert.equal(result.retryable, undefined);
    assert.equal(result.debug_metadata.content_length, 0);
    assert.equal(result.quality.reason, "boilerplate_only");
    assert.ok(result.quality.candidate_content_length > 0);
    assert.ok(result.quality.removed_boilerplate_characters > 0);
  });
}

for (const fixture of [
  "short-article-with-footer.html",
  "structured-schedule-with-navigation.html",
  "link-rich-article-with-footer.html"
]) {
  test(`extractFromRequest preserves production-derived editorial content in ${fixture}`, async () => {
    const html = await readFixture(fixture);
    const result = await extractFixture(html, `https://example.com/${fixture}`);

    assert.equal(result.status, "ok");
    assert.ok(result.content_text.length >= 500);
    assert.doesNotMatch(result.content_text, /Privacy Policy|All rights reserved/);

    if (fixture === "short-article-with-footer.html") {
      assert.ok(result.quality.removed_boilerplate_nodes > 0);
    }
  });
}

test("extractFromRequest reports HTTP errors", async () => {
  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/private"
    },
    {
      fetchImpl: async () =>
        new Response("Forbidden", {
          status: 403,
          headers: { "content-type": "text/html" }
        })
    }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "blocked");
  assert.equal(result.retryable, false);
  assert.equal(result.debug_metadata.status_code, 403);
});

test("extractFromRequest classifies a missing article as not found", async () => {
  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/stale-article-link"
    },
    {
      fetchImpl: async () =>
        new Response("<html><title>Page not found</title></html>", {
          status: 404,
          headers: { "content-type": "text/html" }
        })
    }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "not_found");
  assert.equal(result.retryable, false);
  assert.equal(result.debug_metadata.status_code, 404);
});

test("extractFromRequest reports rate limiting distinctly", async () => {
  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/too-many-requests"
    },
    {
      fetchImpl: async () =>
        new Response("Too Many Requests", {
          status: 429,
          headers: { "content-type": "text/html", "retry-after": "120" }
        })
    }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "rate_limited");
  assert.equal(result.retryable, true);
  assert.equal(result.debug_metadata.status_code, 429);
  assert.equal(result.debug_metadata.retry_after_ms, 120_000);
});

test("parseRetryAfter accepts an HTTP date", () => {
  const retryAt = new Date(Date.now() + 60_000).toUTCString();
  const retryAfterMs = parseRetryAfter(retryAt);

  assert.ok(retryAfterMs >= 59_000);
  assert.ok(retryAfterMs <= 60_000);
});

test("extractFromRequest preserves the final redirect URL", async () => {
  const html = await readFixture("readable-article.html");
  const response = new Response(html, {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8" }
  });

  Object.defineProperty(response, "url", {
    value: "https://example.com/news/canonical-story"
  });

  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/news/redirecting-story",
      options: { minimum_text_length: 100 }
    },
    { fetchImpl: async () => response }
  );

  assert.equal(result.status, "ok");
  assert.equal(result.final_url, "https://example.com/news/canonical-story");
});

test("extractFromRequest rejects unsupported content types", async () => {
  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url: "https://example.com/document.pdf"
    },
    {
      fetchImpl: async () =>
        new Response("%PDF", {
          status: 200,
          headers: { "content-type": "application/pdf" }
        })
    }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "unsupported_content_type");
  assert.equal(result.retryable, false);
});

test("sanitizeArticleHtml removes active content and resolves relative URLs", () => {
  const html = `
    <article onclick="alert('bad')">
      <script>alert('bad')</script>
      <a href="/story" style="color:red">Story</a>
      <img src="/image.jpg" onerror="alert('bad')">
    </article>
  `;

  const sanitized = sanitizeArticleHtml(html, "https://example.com/news/page");

  assert.doesNotMatch(sanitized, /script|onclick|onerror|style=/);
  assert.match(sanitized, /href="https:\/\/example.com\/story"/);
  assert.match(sanitized, /src="https:\/\/example.com\/image.jpg"/);
});

test("sanitizeArticleHtml preserves awkward text delimiters", () => {
  const sanitized = sanitizeArticleHtml(
    "<article><p>An awkward delimiter: ]]&gt; remains article text.</p></article>",
    "https://example.com/news/page"
  );

  assert.match(sanitized, /An awkward delimiter: \]\]&gt; remains article text\./);
});

function fixtureFetch(html, url) {
  return async () =>
    new Response(html, {
      status: 200,
      headers: { "content-type": "text/html; charset=utf-8" }
    });
}

function readFixture(name) {
  return readFile(new URL(`./fixtures/${name}`, import.meta.url), "utf8");
}

function extractFixture(html, url) {
  return extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url,
      options: { minimum_text_length: 500 }
    },
    { fetchImpl: fixtureFetch(html, url) }
  );
}

function extractTextWithLength(length, minimumTextLength) {
  const url = `https://example.com/article-${length}`;
  const html = `<html><head><title>Boundary article</title></head><body><article><p>${"a".repeat(length)}</p></article></body></html>`;

  return extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.simple_html",
      url,
      options: { minimum_text_length: minimumTextLength }
    },
    { fetchImpl: fixtureFetch(html, url) }
  );
}
