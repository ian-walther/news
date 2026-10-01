# News MCP Bridge

An authenticated MCP server that lets Ian's cloud AI agents read the full text
of recently extracted articles, so a scheduled agent can write a daily
personalized newspaper before the application can generate one itself.

## Roles and how to use this document

- **Ian** owns product decisions. Decided items are under "Decisions"; open
  ones are under "Open decisions for Ian".
- **Fable** implements, following `AGENTS.md`.
- **Astra** audits this plan for blind spots before implementation, then the
  implementation against the plan. Findings go in `planning/audit/` with
  stable IDs.

## Why

The Newspaper product in [`newspaper/`](newspaper/README.md) is the
destination, and its local-model compute plan is unchanged. It is not built
yet. Until it is, a frontier model reading the day's full text can produce
most of the reader-facing value. This bridge is **interim**: it should be
small, read-only, and cheap to retire. It must not grow into a second
product or reshape the V2 design.

Local per-article digestion on the RTX 4090 is not required by this bridge.
Whether Ian pauses it meanwhile is an operator choice, not part of this plan
(see "Operator notes").

## Decisions

- **Full text, not summaries.** The agent receives complete extracted article
  text. The frontier model does the summarizing; nothing is pre-condensed and
  nothing is truncated.
- **Few, large reads.** The cost that matters on subscription plans is the
  number of model turns and oversized results being rejected, not the tool
  call itself. One bundle tool returns as much of the window as fits a size
  budget, with a cursor for the rest.
- **Plain Markdown, not HTML or JSON bodies.** Article bodies are returned as
  text with minimal framing.
- **Same server design and OAuth model as the Trilium MCP server**
  (`~/code/triliumnext-mcp`, deployed at `trilium-mcp.ianwalther.com`):
  TypeScript, MCP SDK v2, Streamable HTTP, Auth0 as authorization server, the
  server only verifies tokens.
- **Code lives in this repository**, built from its own Dockerfile and run as
  a second service in `docker-compose.prod.yml`.
- **Publicly reachable**, behind OAuth. The Phoenix application stays
  internal-only.

## Measured sizing basis (production, 2026-10-01)

Read-only queries against the production database:

| Measure | Value |
| --- | --- |
| Extracted articles, total | 13,243 |
| Article text length: mean / median / p90 / max | 4,666 / 3,364 / 8,492 / 256,811 characters |
| Articles over 40,000 / 80,000 characters | 48 / 5 |
| Weekday volume (last 10 days) | 132–182 articles, 620k–825k characters per day |
| Weekend volume | 51–60 articles, about 315k–330k characters per day |
| Largest sources by text, last 7 days | WSJ US Business, The Verge, The Autopian, WSJ World, Ars Technica |
| Output feeds with items in the last 24 h | Tech 60, WSJ 54, Cars 24, F1 10, Music 10, IMSA 6, Indycar 3, Nascar 3 |
| Articles / article sources | 13,266 / 13,426 (cross-source duplication is under 2%) |

At roughly four characters per token a weekday is about 155k–205k tokens and
a weekend day about 80k. Consequences:

- A full weekday does not fit one tool result on any client with a result
  cap, and on heavy days it exceeds a 200k-token context window on its own.
- At the default page budget below, a weekday is **8–11 calls** and a weekend
  day **4–5**.
- The job must be written to work page by page (see "Reference job").

## Architecture

```text
Claude / ChatGPT scheduled agent
        │ HTTPS, OAuth bearer (Auth0)
        ▼
OPNsense nginx  ──▶  N150: news-mcp container (:3940)      ← only public surface
                          │ HTTP + shared bearer token, compose network
                          ▼
                     Phoenix app (:4000)  internal read API  ← stays LAN-only
                          │
                          ▼
                     Postgres
```

- The sidecar holds **no database credentials**. It is a thin client of a
  small internal read API in Phoenix, the same way the Trilium server is a
  client of ETAPI. Selection, ordering, paging, and "what counts as an
  extracted article" live in Elixir, next to the schema they depend on.
- The sidecar reuses, by copy, the Trilium server's configuration loader,
  token verifier, HTTP transport, rate limiter, scope policy, result
  helpers, logging, and audit log. Everything Trilium-specific is dropped.
  HTTP entry point only; a stdio entry point is out of scope.

### Internal read API (Phoenix)

New `Newspaper.Bridge` context and a controller under `/internal/api/v1`,
behind a plug that requires `Authorization: Bearer <NEWSPAPER_BRIDGE_TOKEN>`
(constant-time compare; the routes answer 404 when the variable is unset).
JSON envelope, Markdown bodies.

| Endpoint | Purpose |
| --- | --- |
| `GET /feeds` | Output feeds: id, title, article count in a window |
| `GET /articles` | Index for a window: guid, title, outlet, published time, extracted time, URL, text length, feeds. No bodies. |
| `GET /bundle` | Paged full text for a window (contract below) |
| `GET /articles/:guid` | One article's full text, with `offset` and `max_chars` |

### Bundle contract

Parameters: `since` (required, ISO-8601), `until` (default now), `feeds`
(optional list of output feed ids), `max_chars` (default 80,000; hard maximum
from configuration, initially 320,000), `cursor`.

- **Window clock is extraction time** (`article_extractions.extracted_at`):
  "everything that became readable in this interval". A daily job passes
  yesterday's `until` as today's `since` and can neither miss nor repeat an
  article that was published earlier but extracted late.
- **Snapshot.** `until` is fixed on the first call and carried in the cursor,
  so paging is stable while new articles keep arriving.
- **Order** is deterministic: output feed (canonical feed order), then
  published time, then article id. An article in several selected feeds
  appears once, under the first, with all its feeds named in its header.
- **Each article** is a block: a header (title, outlet, author, published
  time, URL, feeds, guid, length) then the complete text.
- **Pages never split an article** unless the article alone exceeds the page
  budget. An oversized article gets its own page or pages, split at paragraph
  boundaries and labelled "part k of n". Nothing is truncated.
- **Response** carries `next_cursor` (absent on the last page) and totals for
  the whole window: articles, characters, pages at the current budget, and
  how many remain.
- **Only extracted articles** are included. The index endpoint reports
  articles in the window that have no extraction so the agent can say what is
  missing instead of silently omitting it.

### MCP tools (sidecar)

One scope, `news.read`. No write tools.

| Tool | Maps to |
| --- | --- |
| `list_feeds` | `/feeds` |
| `list_articles` | `/articles` |
| `get_news_bundle` | `/bundle` |
| `get_article` | `/articles/:guid` |

Tool results are a single Markdown text block plus structured content for the
cursor and totals. Article bodies are wrapped in an explicit "untrusted
article content" frame in the result text.

## Security design

[`prod-topology.md`](prod-topology.md) requires a separate security design
before any public exposure. This section is that design for the MCP endpoint
only; the Phoenix application's internal-only boundary does not change.

- **Public surface is the sidecar only.** OPNsense proxies a new hostname to
  the sidecar port. Port 4000 is never proxied.
- **Read-only by construction.** The sidecar can only call four GET
  endpoints. It has no database access and no route to any admin action.
- **OAuth resource server.** Tokens are verified against Auth0's keys with
  issuer, audience, expiry, and the `news.read` scope, exactly as in the
  Trilium server. Host allow-list, request body limit, rate limit, and audit
  log are inherited from that code.
- **Internal token.** `NEWSPAPER_BRIDGE_TOKEN` is a random secret shared only
  between the two containers through `.env.prod`. The internal API is
  reachable on the LAN at the same trust level as the existing
  unauthenticated admin UI, so the token adds protection without lowering
  any existing boundary.
- **Content exposure.** Full article text, including subscription content
  extracted through the authenticated browser, leaves the LAN only to
  clients holding Ian's token. There is no anonymous or shared-secret URL
  path.
- **Untrusted content.** Article text can contain instructions aimed at a
  model. The server labels it; the reference job runs with this connector
  alone so a hostile article has no other tool to steer.

## Deployment

- `mcp/` at the repository root: source, `Dockerfile`, tests.
- `docker-compose.prod.yml` gains a `mcp` service (build `./mcp`, depends on
  `app` healthy, publishes one port, `NEWS_API_URL=http://app:4000`), and the
  `app` service gains `NEWSPAPER_BRIDGE_TOKEN`.
- `scripts/deploy-prod.sh` builds and starts both services;
  `scripts/test.sh` and `scripts/precommit.sh` run the sidecar's tests.
- OPNsense: new hostname on the existing certificate, upstream to the N150,
  proxy buffering off, bot protection off, as documented for the Trilium
  server. These are network changes Ian makes or explicitly approves.
- Auth0: a new API whose identifier is the public MCP URL, with the
  `news.read` permission (see the audience question below).
- `architecture.md` and `prod-topology.md` are updated in the same change to
  describe the new public surface.

## Reference job

Shipped as a document under `docs/`: the prompt for a daily scheduled agent.
Shape: call `list_articles` for the window; fetch bundle pages in order;
after each page write durable notes for that page before fetching the next;
compose the paper from the notes; list anything the index reported as
unextracted. This keeps the job correct on a 200k-token context window and
is still fine on larger ones.

## Tests and acceptance

- Elixir: every extracted article in a window appears exactly once across
  all pages for several budgets; oversized articles split without loss;
  snapshot stability while articles arrive mid-paging; multi-feed articles
  appear once; feed scoping; index reports unextracted articles; bearer token
  required, wrong token and unset variable both refuse.
- Sidecar: token verification and scope enforcement (reused tests), tool
  schemas, cursor pass-through, upstream error mapping.
- Acceptance on real clients, recorded in the docs: the largest
  `max_chars` each of Claude Code, a Claude scheduled agent, and ChatGPT
  accepts in one result; a complete weekday pulled end to end with no article
  missing against the index; one full reference-job run.

## Out of scope

- Any write tool, including publishing the generated paper back into the
  application.
- Search, digests, or any server-side summarizing.
- A stdio entry point.
- Changes to the V2 Newspaper design.

## Open decisions for Ian

1. **Public hostname.** Proposed: `news-mcp.ianwalther.com`.
2. **Where the finished paper lands.** This plan leaves it in the agent's own
   output. Publishing it back into the app as a hosted page and RSS item is
   the natural follow-up and needs a write scope.

## Questions for the auditor

1. **Auth0 audience.** The tenant's Default Audience is the Trilium API
   identifier, and the Trilium notes say MCP clients do not send `audience`,
   so tokens are minted for that audience. A second resource server on the
   same tenant would receive tokens with the wrong `aud`. Candidates: confirm
   whether Claude and ChatGPT send an RFC 8707 `resource` parameter that this
   Auth0 tenant can be configured to honor; otherwise use a second Auth0
   tenant for this server. Accepting the Trilium audience here is rejected,
   since it would make a Trilium token valid for news. Which holds up?
2. **Internal API on the shared Phoenix endpoint.** Is a bearer token on a
   route of the LAN-reachable endpoint enough, or should the internal API
   listen on a separate port bound only to the compose network?
3. **Window clock.** Extraction time gives no misses and no repeats for a
   daily job, but an article re-extracted later would reappear. Is "latest
   extraction time" the right clock, or should it be first extraction?
4. **Copying versus sharing** the Trilium server's auth and transport code.
   Copying means two places to patch a security fix. Is that acceptable for
   an interim bridge?
5. **Retirement.** What should be true of the V2 Newspaper before this
   bridge is removed, and is anything here likely to be mistaken for
   permanent surface?

## Operator notes

- Pausing local digestion is safe for this bridge. Output feeds whose title
  or body rendering uses the digest hold new items unpublished while
  digestion is paused; switch those feeds to original rendering first.
