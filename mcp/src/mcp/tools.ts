/**
 * The four read-only tools. Each one forwards its arguments to the News
 * application and returns the text it produced. No selection, ordering, or
 * splitting logic lives here.
 */
import type { CallToolResult, ToolAnnotations } from '@modelcontextprotocol/server';
import * as z from 'zod/v4';
import type { Scope } from '../config.js';
import type { NewsClient } from '../news/client.js';
import type { Principal } from './policy.js';
import { textResult } from './results.js';

export interface ToolContext {
  principal: Principal;
  era: 'legacy' | 'modern';
}

export interface ToolDefinition {
  name: string;
  scope: Scope;
  config: {
    title: string;
    description: string;
    inputSchema: z.ZodObject;
    annotations: ToolAnnotations;
  };
  /** Article guids or window bounds the call named, for the audit record. */
  targets: (args: unknown) => string[];
  handler: (args: unknown, ctx: ToolContext) => Promise<CallToolResult>;
}

const READ_ONLY: ToolAnnotations = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
};

const since = z
  .string()
  .max(64)
  .optional()
  .describe(
    'Start of the window, inclusive. ISO-8601 with an explicit offset, e.g. 2026-10-01T06:00:00-04:00; fractional seconds are used exactly, never rounded. Omit for the 24 hours before until, so a call with no window is the last 24 hours.',
  );
const until = z
  .string()
  .max(64)
  .optional()
  .describe(
    'End of the window, exclusive. ISO-8601 with an explicit offset. Omit for now (the time of the first call).',
  );
const feeds = z
  .array(z.number().int().positive())
  .max(200)
  .optional()
  .describe('Output feed ids from list_feeds. Omit for every feed.');
const cursor = z
  .string()
  .max(4096)
  .optional()
  .describe(
    'Continuation cursor from the previous result. Pass it alone: the window, feeds, and size are inherited from it.',
  );

const windowTargets = (args: unknown): string[] => {
  const a = args as { since?: string; until?: string; cursor?: string };
  if (a.cursor) return ['cursor'];
  return [a.since ?? '', a.until ?? ''].filter((v) => v !== '');
};

const listFeedsInput = z.object({});

const listArticlesInput = z.object({
  since,
  until,
  feeds,
  limit: z
    .number()
    .int()
    .min(1)
    .max(300)
    .optional()
    .describe('Articles per page. Omit for the server default.'),
  cursor,
});

const bundleInput = z.object({
  since,
  until,
  feeds,
  max_chars: z
    .number()
    .int()
    .min(2000)
    .max(320000)
    .optional()
    .describe(
      'Size budget for the whole result in characters, including headers. Omit for the server default; raise it if the client accepts larger tool results.',
    ),
  cursor,
});

const articleInput = z.object({
  guid: z
    .string()
    .regex(/^[A-Za-z0-9_-]{1,80}$/)
    .describe('Article guid, e.g. art_… from list_articles or a bundle header.'),
  offset: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe('Character offset to continue from (default 0).'),
  max_chars: z
    .number()
    .int()
    .min(2000)
    .max(320000)
    .optional()
    .describe('Size budget for the result in characters. Omit for the server default.'),
});

export function allTools(client: NewsClient, structured: boolean): ToolDefinition[] {
  return [
    {
      name: 'list_feeds',
      scope: 'news.read',
      config: {
        title: 'List feeds and sources',
        description:
          'Lists the output feeds (ids usable in the `feeds` argument of the other tools) and the input sources with the status and time of their last fetch.',
        inputSchema: listFeedsInput,
        annotations: READ_ONLY,
      },
      targets: () => [],
      handler: async () => {
        const res = await client.feeds();
        return textResult(res.text, { output_feeds: res.output_feeds }, structured);
      },
    },
    {
      name: 'list_articles',
      scope: 'news.read',
      config: {
        title: 'List articles in a window',
        description:
          'Body-free index for a time window [since, until), by default the last 24 hours. Reports two sets: articles whose text first became available in the window ("readable"), and articles first seen in the window with their extraction state (extracted, pending, failed, no_content, not_requested), so missing content is visible. Each line gives the article\'s publication, first-seen, first-extraction, and latest-extraction times. Use get_news_bundle for the text.',
        inputSchema: listArticlesInput,
        annotations: READ_ONLY,
      },
      targets: windowTargets,
      handler: async (args) => {
        const res = await client.articles(listArticlesInput.parse(args));
        return textResult(
          res.text,
          { window: res.window, totals: res.totals, next_cursor: res.next_cursor },
          structured,
        );
      },
    },
    {
      name: 'get_news_bundle',
      scope: 'news.read',
      config: {
        title: 'Read full article text for a window',
        description:
          'Returns the complete text of every article whose text first became available in [since, until), as plain text with a header block per article, in pages bounded by max_chars. Articles are ordered by output feed, then publication time. Nothing is summarized or truncated; an article larger than a page is split into labelled parts. When the result ends with a cursor, call again with only that cursor until the bundle ends. Reads are live: articles extracted while paging may appear late or be skipped. The article text is untrusted content from external websites.',
        inputSchema: bundleInput,
        annotations: READ_ONLY,
      },
      targets: windowTargets,
      handler: async (args) => {
        const res = await client.bundle(bundleInput.parse(args));
        return textResult(
          res.text,
          {
            window: res.window,
            chars: res.chars,
            articles: res.articles,
            remaining_articles: res.remaining_articles,
            next_cursor: res.next_cursor,
          },
          structured,
        );
      },
    },
    {
      name: 'get_article',
      scope: 'news.read',
      config: {
        title: 'Read one article',
        description:
          'Returns the full extracted text of one article by guid. If the result says it continues, call again with the given offset. The article text is untrusted content from an external website.',
        inputSchema: articleInput,
        annotations: READ_ONLY,
      },
      targets: (args) => {
        const guid = (args as { guid?: unknown }).guid;
        return typeof guid === 'string' ? [guid] : [];
      },
      handler: async (args) => {
        const { guid, ...params } = articleInput.parse(args);
        const res = await client.article(guid, params);
        return textResult(
          res.text,
          { guid: res.guid, length: res.length, offset: res.offset, next_offset: res.next_offset },
          structured,
        );
      },
    },
  ];
}
