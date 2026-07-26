import assert from "node:assert/strict";
import { test } from "node:test";
import {
  extractFromRequest,
  resolveCdpWebSocketEndpoint
} from "../src/extractor.mjs";

test("extractFromRequest uses the persistent context and closes only its temporary page", async () => {
  const state = {
    browserClosed: false,
    contextClosed: false,
    pageClosed: false,
    endpoint: null
  };
  const browser = fakeBrowser(state, articlePage());

  const result = await extractFromRequest(request(), {
    cdpEndpoint: "http://newspaper-browser-host:9223",
    fetch: fakeVersionFetch(),
    chromiumConnector: {
      connectOverCDP: async endpoint => {
        state.endpoint = endpoint;
        return browser;
      }
    }
  });

  assert.equal(result.status, "ok");
  assert.equal(result.implementation, "extraction.headed_browser");
  assert.equal(result.title, "An Authenticated Article");
  assert.match(result.content_text, /persistent signed-in browser profile/);
  assert.equal(
    state.endpoint,
    "ws://newspaper-browser-host:9223/devtools/browser/browser-id"
  );
  assert.equal(state.pageClosed, true);
  assert.equal(state.browserClosed, true);
  assert.equal(state.contextClosed, false);
});

test("extractFromRequest reports an expired authenticated session", async () => {
  const state = {};
  const result = await extractFromRequest(request(), {
    cdpEndpoint: "ws://browser.example/devtools/browser/id",
    chromiumConnector: {
      connectOverCDP: async () => fakeBrowser(state, authRequiredPage())
    }
  });

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "auth_required");
  assert.equal(result.retryable, true);
  assert.match(result.message, /signed-in browser session/i);
  assert.equal(state.pageClosed, true);
  assert.equal(state.browserClosed, true);
});

test("extractFromRequest reports an unavailable persistent browser", async () => {
  const result = await extractFromRequest(request(), {
    cdpEndpoint: "ws://browser.example/devtools/browser/id",
    chromiumConnector: {
      connectOverCDP: async () => {
        throw new Error("connect ECONNREFUSED 172.31.254.1:9223");
      }
    }
  });

  assert.equal(result.status, "failed");
  assert.equal(result.failure_kind, "browser_unavailable");
  assert.equal(result.retryable, true);
  assert.match(result.message, /ECONNREFUSED/);
});

test("resolveCdpWebSocketEndpoint rewrites Chrome loopback metadata through the bridge", async () => {
  const endpoint = await resolveCdpWebSocketEndpoint(
    "http://newspaper-browser-host:9223",
    fakeVersionFetch()
  );

  assert.equal(
    endpoint,
    "ws://newspaper-browser-host:9223/devtools/browser/browser-id"
  );
});

function request() {
  return {
    schema_version: 1,
    implementation: "extraction.headed_browser",
    url: "https://example.com/authenticated-article",
    options: { timeout_ms: 10_000, minimum_text_length: 100 }
  };
}

function fakeVersionFetch() {
  return async url => {
    assert.equal(url, "http://newspaper-browser-host:9223/json/version");

    return {
      ok: true,
      status: 200,
      json: async () => ({
        webSocketDebuggerUrl:
          "ws://127.0.0.1:9222/devtools/browser/browser-id"
      })
    };
  };
}

function fakeBrowser(state, page) {
  const context = {
    newPage: async () => page,
    close: async () => {
      state.contextClosed = true;
    }
  };

  page.close = async () => {
    state.pageClosed = true;
  };

  return {
    contexts: () => [context],
    version: () => "140.0.0.0",
    close: async () => {
      state.browserClosed = true;
    }
  };
}

function articlePage() {
  const html = `
    <!doctype html>
    <html>
      <head><title>An Authenticated Article</title></head>
      <body>
        <article>
          <h1>An Authenticated Article</h1>
          <p>By Ian Example</p>
          <p>This content came from a persistent signed-in browser profile.</p>
          <p>The headed extractor should preserve this useful second paragraph.</p>
          <p>A third paragraph gives Readability enough structure for a stable result.</p>
        </article>
      </body>
    </html>
  `;

  return fakePage({
    url: "https://example.com/authenticated-article",
    html
  });
}

function authRequiredPage() {
  return fakePage({
    url: "https://accounts.example.com/signin?returnTo=%2Fauthenticated-article",
    html: `
      <!doctype html>
      <html>
        <head><title>Sign in</title></head>
        <body>
          <main>
            <h1>Sign in to continue reading</h1>
            <form action="/login"><input type="password"></form>
          </main>
        </body>
      </html>
    `
  });
}

function fakePage({ url, html }) {
  return {
    goto: async () => ({
      status: () => 200,
      allHeaders: async () => ({ "content-type": "text/html; charset=utf-8" })
    }),
    waitForLoadState: async () => {},
    url: () => url,
    content: async () => html,
    close: async () => {}
  };
}
