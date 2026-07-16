import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { extractFromRequest } from "../src/extractor.mjs";

test("extractFromRequest extracts article content rendered by JavaScript", async t => {
  const server = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(dynamicArticleHtml());
  });

  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));

  const address = server.address();
  const url = `http://127.0.0.1:${address.port}/rendered-story`;
  const result = await extractFromRequest({
    schema_version: 1,
    implementation: "extraction.headless_browser",
    url,
    options: { timeout_ms: 10_000, minimum_text_length: 100 }
  });

  assert.equal(result.status, "ok");
  assert.equal(result.implementation, "extraction.headless_browser");
  assert.equal(result.final_url, url);
  assert.equal(result.title, "A Browser Rendered Article");
  assert.match(result.content_text, /rendered after JavaScript executed/);
  assert.equal(result.debug_metadata.browser, "chromium");
  assert.ok(result.debug_metadata.rendered_html_bytes > 0);
});

test("extractFromRequest preserves browser HTTP failures", async () => {
  const result = await extractFromRequest(
    {
      schema_version: 1,
      implementation: "extraction.headless_browser",
      url: "https://example.com/private"
    },
    { chromiumLauncher: fakeLauncher(403) }
  );

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "blocked");
  assert.equal(result.retryable, false);
  assert.equal(result.debug_metadata.status_code, 403);
});

function dynamicArticleHtml() {
  const article = `
    <article>
      <h1>A Browser Rendered Article</h1>
      <p>By Ian Example</p>
      <p>This body was rendered after JavaScript executed in an isolated browser.</p>
      <p>The headless extractor should preserve this useful second paragraph too.</p>
      <p>A third paragraph gives Readability enough structure for a stable result.</p>
    </article>
  `;

  return `
    <!doctype html>
    <html>
      <head><title>Loading</title></head>
      <body>
        <main id="root">Loading article...</main>
        <script>
          setTimeout(() => {
            document.title = "A Browser Rendered Article";
            document.querySelector("#root").innerHTML = ${JSON.stringify(article)};
          }, 25);
        </script>
      </body>
    </html>
  `;
}

function fakeLauncher(statusCode) {
  const page = {
    goto: async () => ({
      status: () => statusCode,
      allHeaders: async () => ({ "content-type": "text/html" })
    }),
    waitForLoadState: async () => {},
    url: () => "https://example.com/private",
    content: async () => "<html></html>"
  };

  const browser = {
    newContext: async () => ({ newPage: async () => page }),
    version: () => "1.0.0",
    close: async () => {}
  };

  return { launch: async () => browser };
}
