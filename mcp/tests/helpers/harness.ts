/** Shared wiring for protocol tests: fake News API + app context + HTTP transport. */
import { createAppContext, type AppContext } from '../../src/app.js';
import { loadConfig } from '../../src/config.js';
import { silentLogger, type AuditEvent, type Logger } from '../../src/logging/logger.js';
import {
  createHttpTransport,
  type HttpTransport,
  type HttpTransportOptions,
} from '../../src/transport/http.js';
import { FakeNews } from './fakeNews.js';

export interface Harness {
  fake: FakeNews;
  ctx: AppContext;
  transport: HttpTransport;
  audit: AuditEvent[];
  fetch: (input: string | URL, init?: RequestInit) => Promise<Response>;
  close(): Promise<void>;
}

export function createHarness(
  env: NodeJS.ProcessEnv = {},
  options: HttpTransportOptions & { logger?: Logger } = {},
): Harness {
  const fake = new FakeNews();
  const config = loadConfig(
    { NEWS_API_URL: 'http://fake-news:4000', MCP_AUDIT_ENABLED: 'true', ...env },
    { version: '0.0.0-test' },
  );
  const audit: AuditEvent[] = [];
  const ctx = createAppContext({
    config,
    fetch: fake.fetch,
    logger: options.logger ?? silentLogger,
  });
  ctx.audit = { record: (e) => void audit.push(e) };
  const transport = createHttpTransport(ctx, options);
  const fetchFn = (input: string | URL, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' ? input : input.toString());
    const headers = new Headers(init?.headers);
    // A hand-built Request has no Host header; the Node adapter sets it in production.
    if (!headers.has('host')) headers.set('host', url.host);
    return Promise.resolve(transport.app.fetch(new Request(url, { ...init, headers })));
  };
  return { fake, ctx, transport, audit, fetch: fetchFn, close: () => transport.close() };
}
