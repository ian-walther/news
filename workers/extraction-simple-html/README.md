# Simple HTML Extraction Worker

Direct HTML article extraction executable for Newspaper.

Readable HTML is sanitized before it leaves the worker. Executable media embeds, low-prose player wrappers, decorative player chrome, and explicit embed-fallback links are removed before Readability while ordinary article figures remain intact. Relative article links and image URLs are resolved against the final fetched URL so the stored fragment can be rendered by Newspaper without publisher CSS or active page content. Extraction quality and debug metadata report removed embedded-media node and character counts for auditing.

This worker is the first and cheapest extraction strategy in the app-owned escalation chain:

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

It reads one JSON request from stdin and writes one JSON response to stdout.
Human-readable diagnostics should go to stderr.

## Run

```sh
cd workers
npm ci
npm test
echo '{"schema_version":1,"implementation":"extraction.simple_html","url":"https://example.com/article"}' | extraction-simple-html/bin/extract
```

## Request

```json
{
  "schema_version": 1,
  "implementation": "extraction.simple_html",
  "url": "https://example.com/article",
  "metadata": {},
  "options": {
    "timeout_ms": 20000,
    "minimum_text_length": 500
  }
}
```

## Response

Successful extraction:

```json
{
  "schema_version": 1,
  "implementation": "extraction.simple_html",
  "status": "ok",
  "final_url": "https://example.com/article",
  "title": "Article title",
  "byline": "Author",
  "published_at": "2026-06-18T12:30:00.000Z",
  "content_html": "<div>...</div>",
  "content_text": "Article text...",
  "excerpt": "Short excerpt",
  "site_name": "Example",
  "quality": {
    "score": 0.9,
    "reason": "sufficient_content"
  },
  "debug_metadata": {}
}
```

Valid no-content outcome:

```json
{
  "schema_version": 1,
  "implementation": "extraction.simple_html",
  "status": "no_content",
  "final_url": "https://example.com/article",
  "reason": "boilerplate_only",
  "message": "boilerplate_only",
  "quality": {
    "score": 0,
    "reason": "boilerplate_only"
  },
  "debug_metadata": {}
}
```

A no-content response is successful execution with no usable article body. It allows the application to try a more capable extractor and, if the chain is exhausted, record a valid skipped outcome rather than a failure.

Network, HTTP, and worker failures use `status: "failed"`. Rate-limited responses use `failure_kind: "rate_limited"`. When the server provides a valid `Retry-After` header, `debug_metadata.retry_after_ms` carries the requested delay for app-owned per-host scheduling.
