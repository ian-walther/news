/** A stand-in for the Phoenix read API: canned JSON per path, with a request log. */
export interface RecordedRequest {
  path: string;
  query: Record<string, string>;
}

export class FakeNews {
  requests: RecordedRequest[] = [];
  /** Return a Response to short-circuit a request (simulate errors or outages). */
  intercept: ((request: RecordedRequest) => Response | undefined) | undefined;

  readonly fetch = (input: string | URL): Promise<Response> => {
    const url = new URL(typeof input === 'string' ? input : input.toString());
    const request: RecordedRequest = {
      path: url.pathname.replace('/internal/api/v1', ''),
      query: Object.fromEntries(url.searchParams),
    };
    this.requests.push(request);
    const intercepted = this.intercept?.(request);
    if (intercepted) return Promise.resolve(intercepted);
    return Promise.resolve(this.respond(request));
  };

  private respond({ path, query }: RecordedRequest): Response {
    if (path === '/feeds') {
      return Response.json({
        text: 'Output feeds (use these ids to scope a window):\n- 9 | Tech',
        output_feeds: [{ id: 9, title: 'Tech', enabled: true }],
        sources: [],
      });
    }
    if (path === '/articles') {
      return Response.json({
        text: 'Article index\n- art_one | extracted\n[End of index.]',
        window: { since: '2026-09-30T00:00:00Z', until: '2026-10-01T00:00:00Z' },
        feeds: null,
        limit: 150,
        totals: { readable: 1, first_seen: 1, first_seen_by_state: { extracted: 1 } },
        articles: [{ guid: 'art_one' }],
        next_cursor: null,
      });
    }
    if (path === '/bundle') {
      const continued = query['cursor'] === 'CURSOR-2';
      return Response.json({
        text: continued
          ? 'page two body\n[End of bundle.]'
          : 'page one body\n[Continues. 1 article not yet fully returned. Call again with cursor: CURSOR-2]',
        window: { since: '2026-09-30T00:00:00Z', until: '2026-10-01T00:00:00Z' },
        feeds: null,
        max_chars: 80000,
        chars: 100,
        articles: [{ guid: continued ? 'art_two' : 'art_one', part: null, parts: null }],
        remaining_articles: continued ? 0 : 1,
        next_cursor: continued ? null : 'CURSOR-2',
      });
    }
    if (path === '/articles/art_one') {
      return Response.json({
        text: 'article one text\n[End of article.]',
        guid: 'art_one',
        length: 16,
        offset: Number(query['offset'] ?? 0),
        next_offset: null,
        chars: 40,
      });
    }
    return Response.json(
      { error: { code: 'not_found', message: 'No extracted article has that guid' } },
      { status: 404 },
    );
  }
}
