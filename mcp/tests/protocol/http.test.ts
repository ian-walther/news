import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from 'jose';
import { afterEach, describe, expect, it } from 'vitest';
import { createOidcVerifier } from '../../src/auth/verifier.js';
import { createHarness, type Harness } from '../helpers/harness.js';

const URL_ = 'http://127.0.0.1:3940/mcp';
const JSON_HEADERS = {
  'content-type': 'application/json',
  accept: 'application/json, text/event-stream',
};
const PING = '{"jsonrpc":"2.0","id":1,"method":"ping"}';

let harness: Harness | undefined;
const clients: Client[] = [];

afterEach(async () => {
  for (const c of clients.splice(0)) await c.close().catch(() => undefined);
  await harness?.close();
  harness = undefined;
});

function connect(h: Harness, options: { modern?: boolean; token?: string } = {}): Promise<Client> {
  const client = new Client(
    { name: 'test', version: '1' },
    options.modern ? { versionNegotiation: { mode: 'auto' } } : {},
  );
  const transport = new StreamableHTTPClientTransport(new URL(URL_), {
    fetch: (url, init) => {
      const headers = new Headers(init?.headers);
      if (options.token) headers.set('authorization', `Bearer ${options.token}`);
      return h.fetch(url, { ...init, headers });
    },
  });
  clients.push(client);
  return client.connect(transport).then(() => client);
}

const text = (res: { content?: unknown }): string =>
  (res.content as { type: string; text: string }[])[0]!.text;

describe('HTTP transport (auth none, loopback)', () => {
  for (const modern of [false, true]) {
    it(`serves the ${modern ? 'modern' : 'legacy'} era: list, call, paging, errors, audit`, async () => {
      harness = createHarness();
      const client = await connect(harness, { modern });
      expect(client.getProtocolEra()).toBe(modern ? 'modern' : 'legacy');

      const tools = await client.listTools();
      expect(tools.tools.map((t) => t.name)).toEqual([
        'list_feeds',
        'list_articles',
        'get_news_bundle',
        'get_article',
      ]);
      for (const tool of tools.tools) {
        expect(tool.annotations?.readOnlyHint).toBe(true);
        expect(tool.annotations?.destructiveHint).toBe(false);
      }

      const feeds = await client.callTool({ name: 'list_feeds', arguments: {} });
      expect(text(feeds)).toContain('- 9 | Tech');

      const first = await client.callTool({
        name: 'get_news_bundle',
        arguments: { since: '2026-09-30T00:00:00Z', feeds: [9], max_chars: 5000 },
      });
      expect(first.isError).toBeFalsy();
      // The text is the application's text, unchanged, and carries the cursor itself.
      expect(text(first)).toBe(
        'page one body\n[Continues. 1 article not yet fully returned. Call again with cursor: CURSOR-2]',
      );
      const meta = first.structuredContent as { next_cursor: string; remaining_articles: number };
      expect(meta.next_cursor).toBe('CURSOR-2');
      expect(meta.remaining_articles).toBe(1);
      expect(first.structuredContent).not.toHaveProperty('text');

      const second = await client.callTool({
        name: 'get_news_bundle',
        arguments: { cursor: meta.next_cursor },
      });
      expect(text(second)).toContain('[End of bundle.]');
      expect(harness.fake.requests.at(-1)).toEqual({
        path: '/bundle',
        query: { cursor: 'CURSOR-2' },
      });

      const one = await client.callTool({ name: 'get_article', arguments: { guid: 'art_one' } });
      expect(text(one)).toContain('article one text');

      const missing = await client.callTool({
        name: 'get_article',
        arguments: { guid: 'art_nope' },
      });
      expect(missing.isError).toBe(true);
      expect((missing.structuredContent as { error: { code: string } }).error.code).toBe(
        'NOT_FOUND',
      );

      const invalid = await client.callTool({
        name: 'get_article',
        arguments: { guid: '../../etc/passwd' },
      });
      expect(invalid.isError).toBe(true);

      expect(harness.audit.map((a) => [a.tool, a.ok, a.principal])).toEqual([
        ['list_feeds', true, 'anonymous'],
        ['get_news_bundle', true, 'anonymous'],
        ['get_news_bundle', true, 'anonymous'],
        ['get_article', true, 'anonymous'],
        ['get_article', false, 'anonymous'],
        ['get_article', false, 'anonymous'], // schema-rejected guid
      ]);
      expect(harness.audit[5]?.code).toBe('INVALID_ARGUMENTS');
      expect(harness.audit[3]?.targets).toEqual(['art_one']);
      expect(harness.audit[1]?.targets).toEqual(['2026-09-30T00:00:00Z']);
      expect(harness.audit[2]?.targets).toEqual(['cursor']);
    });
  }

  it('passes application errors through with their codes', async () => {
    harness = createHarness();
    const client = await connect(harness);
    harness.fake.intercept = () =>
      Response.json(
        { error: { code: 'budget_too_small', message: 'max_chars is too small' } },
        { status: 422 },
      );
    const res = await client.callTool({
      name: 'get_news_bundle',
      arguments: { since: '2026-09-30T00:00:00Z', max_chars: 2000 },
    });
    expect(res.isError).toBe(true);
    expect(res.structuredContent).toEqual({
      error: { code: 'BUDGET_TOO_SMALL', message: 'max_chars is too small' },
    });
  });

  it('can return text-only results', async () => {
    harness = createHarness({ MCP_RESULT_STRUCTURED: 'false' });
    const client = await connect(harness);
    const res = await client.callTool({
      name: 'get_news_bundle',
      arguments: { since: '2026-09-30T00:00:00Z' },
    });
    expect(res.structuredContent).toBeUndefined();
    expect(text(res)).toContain('cursor: CURSOR-2');
  });

  it('exposes a health endpoint without article content', async () => {
    harness = createHarness({}, { healthCacheMs: 0 });
    const res = await harness.fetch('http://127.0.0.1:3940/healthz');
    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ status: 'ok', news: { reachable: true } });
    harness.fake.intercept = () => new Response('down', { status: 503 });
    const down = await harness.fetch('http://127.0.0.1:3940/healthz');
    expect(down.status).toBe(503);
  });

  it('rejects requests with a foreign Host header (DNS rebinding)', async () => {
    harness = createHarness();
    const res = await harness.fetch('http://evil.example/mcp', {
      method: 'POST',
      headers: JSON_HEADERS,
      body: '{}',
    });
    expect(res.status).toBe(403);
  });

  it('rate limits per client', async () => {
    harness = createHarness({ MCP_RATE_LIMIT_PER_MINUTE: '60', MCP_RATE_LIMIT_BURST: '2' });
    const client = await connect(harness); // consumes budget during the handshake
    const results: number[] = [];
    for (let i = 0; i < 4; i++) {
      const res = await harness.fetch(URL_, {
        method: 'POST',
        headers: JSON_HEADERS,
        body: JSON.stringify({ jsonrpc: '2.0', id: i, method: 'ping' }),
      });
      results.push(res.status);
    }
    expect(results).toContain(429);
    await client.close();
  });
});

describe('HTTP transport (static tokens)', () => {
  const TOKEN = 'readonly-token-0123456789';
  const env = { MCP_AUTH_MODE: 'static', MCP_STATIC_TOKENS: `ian@${TOKEN}:news.read` };

  it('challenges missing and invalid tokens and serves a valid one', async () => {
    harness = createHarness(env);
    const anon = await harness.fetch(URL_, { method: 'POST', headers: JSON_HEADERS, body: PING });
    expect(anon.status).toBe(401);
    expect(anon.headers.get('www-authenticate')).toMatch(/Bearer/);
    const bad = await harness.fetch(URL_, {
      method: 'POST',
      headers: { ...JSON_HEADERS, authorization: 'Bearer nope' },
      body: PING,
    });
    expect(bad.status).toBe(401);
    // No request reached the application for unauthenticated callers.
    expect(harness.fake.requests).toEqual([]);

    const client = await connect(harness, { token: TOKEN });
    const res = await client.callTool({ name: 'list_feeds', arguments: {} });
    expect(res.isError).toBeFalsy();
    expect(harness.audit.at(-1)?.principal).toBe('ian');
  });

  it('accepts the public hostname and loopback on a non-loopback bind', async () => {
    harness = createHarness({
      ...env,
      MCP_HTTP_HOST: '0.0.0.0',
      MCP_PUBLIC_URL: 'https://news-mcp.example.net/mcp',
    });
    const body = { method: 'POST', headers: JSON_HEADERS, body: PING } as const;
    expect((await harness.fetch('https://news-mcp.example.net/mcp', body)).status).toBe(401);
    expect((await harness.fetch('http://127.0.0.1:3940/healthz')).status).toBe(200);
    expect((await harness.fetch('http://evil.example/mcp', body)).status).toBe(403);
  });
});

describe('HTTP transport (oidc)', () => {
  it('verifies JWTs, publishes protected-resource metadata, and enforces audience and scope', async () => {
    const pair = await generateKeyPair('RS256');
    const jwk = await exportJWK(pair.publicKey);
    const getKey = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k', alg: 'RS256' }] });
    const env = {
      MCP_AUTH_MODE: 'oidc',
      MCP_OIDC_ISSUER: 'https://tenant.auth0.com/',
      MCP_PUBLIC_URL: 'https://news-mcp.example.net/mcp',
    };
    harness = createHarness(env);
    const verifier = createOidcVerifier(harness.ctx.config.auth.oidc!, { getKey });
    await harness.close();
    harness = createHarness(env, { verifier });

    const prm = await harness.fetch(
      'http://127.0.0.1:3940/.well-known/oauth-protected-resource/mcp',
    );
    expect(prm.status).toBe(200);
    expect(await prm.json()).toMatchObject({
      resource: 'https://news-mcp.example.net/mcp',
      authorization_servers: ['https://tenant.auth0.com/'],
      scopes_supported: ['news.read'],
    });

    const challenge = await harness.fetch(URL_, {
      method: 'POST',
      headers: JSON_HEADERS,
      body: PING,
    });
    expect(challenge.status).toBe(401);
    expect(challenge.headers.get('www-authenticate')).toContain(
      'resource_metadata="https://news-mcp.example.net/.well-known/oauth-protected-resource/mcp"',
    );

    const sign = (claims: Record<string, unknown>, audience: string) =>
      new SignJWT(claims)
        .setProtectedHeader({ alg: 'RS256', kid: 'k' })
        .setIssuer('https://tenant.auth0.com/')
        .setAudience(audience)
        .setSubject('auth0|ian')
        .setIssuedAt()
        .setExpirationTime('5m')
        .sign(pair.privateKey);

    // A Trilium token from the same tenant is not valid here.
    const trilium = await sign({ scope: 'trilium.read' }, 'https://trilium-mcp.example.net/mcp');
    const rejected = await harness.fetch(URL_, {
      method: 'POST',
      headers: { ...JSON_HEADERS, authorization: `Bearer ${trilium}` },
      body: PING,
    });
    expect(rejected.status).toBe(401);

    // A tenant login without the news.read permission gets no tools.
    const scopeless = await sign({ scope: 'openid profile' }, 'https://news-mcp.example.net/mcp');
    const stranger = await connect(harness, { token: scopeless, modern: true });
    expect((await stranger.listTools()).tools).toEqual([]);

    const token = await sign({ scope: 'news.read' }, 'https://news-mcp.example.net/mcp');
    const client = await connect(harness, { token, modern: true });
    expect((await client.listTools()).tools.map((t) => t.name)).toContain('get_news_bundle');
    const res = await client.callTool({ name: 'list_feeds', arguments: {} });
    expect(res.isError).toBeFalsy();
    expect(harness.audit.at(-1)?.principal).toBe('auth0|ian');
  });
});
