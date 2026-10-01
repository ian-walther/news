/**
 * Thin client for the Phoenix application's read API (`/internal/api/v1`).
 * Selection, ordering, paging, and all text splitting happen in the
 * application; this client only carries parameters there and text back.
 */
import { BridgeError } from '../errors.js';

export type FetchLike = (input: string | URL, init?: RequestInit) => Promise<Response>;

export interface NewsClientOptions {
  baseUrl: string;
  timeoutMs: number;
  userAgent: string;
  fetch?: FetchLike;
}

export interface WindowParams {
  since?: string | undefined;
  until?: string | undefined;
  feeds?: number[] | undefined;
  cursor?: string | undefined;
}

export interface FeedsResponse {
  text: string;
  output_feeds: { id: number; title: string; enabled: boolean }[];
  sources: unknown[];
}

export interface IndexResponse {
  text: string;
  window: { since: string; until: string };
  feeds: number[] | null;
  limit: number;
  totals: { readable: number; first_seen: number; first_seen_by_state: Record<string, number> };
  articles: unknown[];
  next_cursor: string | null;
}

export interface BundleResponse {
  text: string;
  window: { since: string; until: string };
  feeds: number[] | null;
  max_chars: number;
  chars: number;
  articles: { guid: string; part: number | null; parts: number | null }[];
  remaining_articles: number;
  next_cursor: string | null;
}

export interface ArticleResponse {
  text: string;
  guid: string;
  length: number;
  offset: number;
  next_offset: number | null;
  chars: number;
}

type Query = Record<string, string | number | number[] | undefined>;

export class NewsClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly userAgent: string;
  private readonly fetchImpl: FetchLike;

  constructor(options: NewsClientOptions) {
    this.baseUrl = `${options.baseUrl.replace(/\/+$/, '')}/internal/api/v1`;
    this.timeoutMs = options.timeoutMs;
    this.userAgent = options.userAgent;
    this.fetchImpl = options.fetch ?? ((input, init) => fetch(input, init));
  }

  feeds(): Promise<FeedsResponse> {
    return this.get<FeedsResponse>('/feeds', {});
  }

  articles(params: WindowParams & { limit?: number | undefined }): Promise<IndexResponse> {
    return this.get<IndexResponse>('/articles', { ...params });
  }

  bundle(params: WindowParams & { max_chars?: number | undefined }): Promise<BundleResponse> {
    return this.get<BundleResponse>('/bundle', { ...params });
  }

  article(
    guid: string,
    params: { offset?: number | undefined; max_chars?: number | undefined },
  ): Promise<ArticleResponse> {
    return this.get<ArticleResponse>(`/articles/${encodeURIComponent(guid)}`, { ...params });
  }

  /** Reachability probe for the health endpoint. */
  async ping(): Promise<void> {
    await this.feeds();
  }

  private async get<T>(path: string, query: Query): Promise<T> {
    const url = new URL(`${this.baseUrl}${path}`);
    for (const [key, value] of Object.entries(query)) {
      if (value === undefined) continue;
      url.searchParams.set(key, Array.isArray(value) ? value.join(',') : String(value));
    }

    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method: 'GET',
        headers: { accept: 'application/json', 'user-agent': this.userAgent },
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      throw new BridgeError(
        'UPSTREAM_UNAVAILABLE',
        'The News application could not be reached',
        {},
        err,
      );
    }

    let body: unknown;
    try {
      body = await response.json();
    } catch (err) {
      throw new BridgeError(
        response.status >= 500 ? 'UPSTREAM_UNAVAILABLE' : 'UPSTREAM',
        `News API answered ${response.status} without JSON`,
        { upstreamStatus: response.status },
        err,
      );
    }

    if (!response.ok) {
      const error = (body as { error?: { code?: unknown; message?: unknown } } | null)?.error;
      throw BridgeError.fromUpstream(
        response.status,
        typeof error?.code === 'string' ? error.code : undefined,
        typeof error?.message === 'string' ? error.message : 'request failed',
      );
    }
    return body as T;
  }
}
