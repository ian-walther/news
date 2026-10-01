import { describe, expect, it } from 'vitest';
import { BridgeError } from '../../src/errors.js';
import { NewsClient } from '../../src/news/client.js';
import { FakeNews } from '../helpers/fakeNews.js';

function client(fake: FakeNews): NewsClient {
  return new NewsClient({
    baseUrl: 'http://app:4000/',
    timeoutMs: 1000,
    userAgent: 'test/0',
    fetch: fake.fetch,
  });
}

describe('NewsClient', () => {
  it('sends only the parameters it was given and joins feed ids', async () => {
    const fake = new FakeNews();
    await client(fake).bundle({
      since: '2026-09-30T00:00:00Z',
      feeds: [9, 4],
      max_chars: 5000,
      until: undefined,
      cursor: undefined,
    });
    expect(fake.requests).toEqual([
      {
        path: '/bundle',
        query: { since: '2026-09-30T00:00:00Z', feeds: '9,4', max_chars: '5000' },
      },
    ]);
  });

  it('passes a cursor through untouched and adds nothing', async () => {
    const fake = new FakeNews();
    const page = await client(fake).bundle({ cursor: 'CURSOR-2' });
    expect(fake.requests[0]).toEqual({ path: '/bundle', query: { cursor: 'CURSOR-2' } });
    expect(page.next_cursor).toBeNull();
  });

  it('encodes the guid in the path', async () => {
    const fake = new FakeNews();
    await client(fake).article('art_one', { offset: 10 });
    expect(fake.requests[0]).toEqual({ path: '/articles/art_one', query: { offset: '10' } });
  });

  it('maps application error bodies to stable codes', async () => {
    const fake = new FakeNews();
    const cases: [number, string, string][] = [
      [400, 'invalid_parameter', 'INVALID_PARAMETER'],
      [400, 'invalid_cursor', 'INVALID_CURSOR'],
      [400, 'cursor_parameter_mismatch', 'CURSOR_PARAMETER_MISMATCH'],
      [422, 'budget_too_small', 'BUDGET_TOO_SMALL'],
      [404, 'not_found', 'NOT_FOUND'],
      [400, 'something_new', 'UPSTREAM'],
    ];
    for (const [status, code, expected] of cases) {
      fake.intercept = () => Response.json({ error: { code, message: 'because' } }, { status });
      const err = await client(fake)
        .bundle({ since: 'x' })
        .catch((e: unknown) => e);
      expect(err).toBeInstanceOf(BridgeError);
      expect((err as BridgeError).code).toBe(expected);
    }
  });

  it('reports outages and non-JSON answers as unavailable', async () => {
    const fake = new FakeNews();
    fake.intercept = () => new Response('<html>502</html>', { status: 502 });
    await expect(client(fake).feeds()).rejects.toMatchObject({ code: 'UPSTREAM_UNAVAILABLE' });
    fake.intercept = () => Response.json({ error: {} }, { status: 500 });
    await expect(client(fake).feeds()).rejects.toMatchObject({ code: 'UPSTREAM_UNAVAILABLE' });
    const down = new NewsClient({
      baseUrl: 'http://app:4000',
      timeoutMs: 1000,
      userAgent: 'test/0',
      fetch: () => Promise.reject(new TypeError('fetch failed')),
    });
    await expect(down.feeds()).rejects.toMatchObject({ code: 'UPSTREAM_UNAVAILABLE' });
  });
});
