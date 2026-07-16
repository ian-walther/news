import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import {
  extractFromRequest,
  parseReadableArticle,
  sanitizeArticleHtml
} from "../src/extractor.mjs";

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

test("extractFromRequest reports insufficient content", async () => {
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

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "insufficient_content");
  assert.equal(result.retryable, false);
});

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

function fixtureFetch(html, url) {
  return async () =>
    new Response(html, {
      status: 200,
      headers: { "content-type": "text/html; charset=utf-8" }
    });
}
